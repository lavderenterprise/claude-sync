import Foundation
import CryptoKit

// MARK: - Deterministic identities (idempotency: re-running any conversion regenerates
// the exact same ids, so retries converge instead of duplicating)

enum DeterministicID {
    /// UUIDv7-shaped id for a Codex thread derived from its Claude twin: 48-bit ms
    /// timestamp + SHA-256 tail. Sorts correctly among genuine v7 ids.
    static func codexThreadId(claudeId: String, createdAtMs: Int) -> String {
        var b = [UInt8](repeating: 0, count: 16)
        let ts = UInt64(max(createdAtMs, 0))
        for i in 0..<6 { b[i] = UInt8((ts >> (8 * (5 - i))) & 0xFF) }
        let h = [UInt8](SHA256.hash(data: Data(("css:" + claudeId).utf8)))
        for i in 0..<10 { b[6 + i] = h[i] }
        b[6] = (b[6] & 0x0F) | 0x70
        b[8] = (b[8] & 0x3F) | 0x80
        return format(b)
    }

    /// UUIDv5 (SHA-1, namespaced) — for Claude session ids and per-line uuids derived
    /// from Codex material.
    static func uuidV5(_ name: String) -> String {
        // Fixed namespace for this app (random constant, stable forever).
        let ns: [UInt8] = [0x5c, 0x55, 0x0d, 0x8a, 0x91, 0x3e, 0x4a, 0x7f,
                           0x9b, 0x02, 0xd6, 0x41, 0xcc, 0x2a, 0x77, 0x31]
        var data = Data(ns)
        data.append(Data(name.utf8))
        var b = [UInt8](Insecure.SHA1.hash(data: data)).prefix(16).map { $0 }
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return format(b)
    }

    static func claudeSessionId(codexId: String) -> String { uuidV5("claude:" + codexId) }
    static func lineUuid(codexId: String, index: Int) -> String { uuidV5(codexId + "#\(index)") }
    static func turnId(codexId: String, index: Int) -> String { uuidV5("turn:" + codexId + "#\(index)") }
    static func indexFileId(claudeId: String) -> String { uuidV5("index:" + claudeId) }

    private static func format(_ b: [UInt8]) -> String {
        let hex = b.map { String(format: "%02x", $0) }.joined()
        var s = ""
        for (i, c) in hex.enumerated() {
            if [8, 12, 16, 20].contains(i) { s += "-" }
            s.append(c)
        }
        return s
    }
}

// MARK: - Text renderers (tool traffic crosses formats as inert readable text)

// Rendering replicates OpenAI's own /import (codex-rs/external-agent-migration,
// sessions/records.rs): bounded [external_agent_tool_call]/[external_agent_tool_result]
// tags with key fields extracted, 2000/4000-char caps, unsupported blocks made visible.
private let noteMaxLen = 2000
private let toolResultMaxLen = 4000

private func truncated(_ s: String, _ cap: Int) -> String {
    s.count > cap ? String(s.prefix(cap)) : s
}

func renderToolUse(name: String, input: Any?) -> String {
    var lines = ["[external_agent_tool_call: \(name)]"]
    if let dict = input as? [String: Any] {
        if let d = dict["description"] as? String { lines.append("description: \(d)") }
        if let c = dict["command"] as? String { lines.append("command: \(c)") }
        if let f = (dict["file_path"] as? String) ?? (dict["file"] as? String) {
            lines.append("file: \(f)")
        }
        if lines.count == 1,
           let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            lines.append("input: \(truncated(json, noteMaxLen))")
        }
    } else if let s = input as? String, !s.isEmpty {
        lines.append("input: \(truncated(s, noteMaxLen))")
    }
    lines.append("[/external_agent_tool_call]")
    return lines.joined(separator: "\n")
}

func renderToolResult(_ text: String, isError: Bool) -> String {
    let label = isError ? "[external_agent_tool_result: error]" : "[external_agent_tool_result]"
    if text.isEmpty { return label + "\n[/external_agent_tool_result]" }
    return label + "\n" + truncated(text, toolResultMaxLen) + "\n[/external_agent_tool_result]"
}

func epochSeconds(_ iso: String) -> Int? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: iso) { return Int(d.timeIntervalSince1970) }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso).map { Int($0.timeIntervalSince1970) }
}

/// Flattens heterogeneous content (string | [{type:text,…}]) to plain text.
func flattenContent(_ content: Any?) -> String {
    if let s = content as? String { return s }
    if let arr = content as? [[String: Any]] {
        // Newer Codex builds emit typed blocks (`input_text` on custom_tool_call_output,
        // `output_text` elsewhere) instead of plain `text` — accept every text-bearing kind.
        return arr.compactMap { item -> String? in
            guard let t = item["type"] as? String,
                  t == "text" || t == "input_text" || t == "output_text" else { return nil }
            return item["text"] as? String
        }.joined(separator: "\n")
    }
    return ""
}

// MARK: - Claude → Codex (incremental emitter; scales to arbitrarily large regions)

/// Feed Claude lines one at a time; rollout lines come out. The structure replicates
/// OpenAI's native importer (sessions/export.rs) exactly: no per-turn turn_context,
/// readable turn ids, tool traffic inline as bounded tags, tool-result-only user lines
/// demoted to assistant continuations, and an import marker + token estimate at the end.
final class ClaudeToCodexEmitter {
    struct Stats {
        var lastConsumedUuid: String?
        var consumedLineCount = 0
        var turnsEmitted = 0
        var skippedUnknown = 0
        var firstUserText: String?
        var lastTimestamp = ""
    }

    private let codexId: String
    private let cwd: String
    private var turnIndex: Int
    private var currentTurnId: String?
    private var currentTurnStartedAt: Int?      // epoch seconds
    private var responseBytes = 0
    private var lastTimestampSecs: Int?
    private(set) var stats = Stats()

    init(codexId: String, cwd: String, startTurnIndex: Int) {
        self.codexId = codexId
        self.cwd = cwd
        self.turnIndex = startTurnIndex
    }

    static func preamble(metaTemplate: [String: Any], codexId: String, cwd: String,
                         createdAtISO: String) -> [String: Any] {
        var meta = metaTemplate
        meta["id"] = codexId
        meta["timestamp"] = createdAtISO
        meta["cwd"] = cwd
        meta["originator"] = "claude_session_sync"
        return ["timestamp": createdAtISO, "type": "session_meta", "payload": meta]
    }

    func feed(_ line: ClaudeLine) -> [[String: Any]] {
        stats.consumedLineCount += 1
        if let u = line.uuid { stats.lastConsumedUuid = u }
        let ts = line.timestamp ?? isoNow()
        stats.lastTimestamp = ts
        let tsSecs = epochSeconds(ts)
        if tsSecs != nil { lastTimestampSecs = tsSecs }

        guard !line.isSidechain, !line.isMeta,
              line.type == "user" || line.type == "assistant" else {
            if line.type != "user", line.type != "assistant",
               !["system", "attachment", "queue-operation", "last-prompt", "mode",
                 "pr-link", "ai-title", "custom-title", "file", "summary"].contains(line.type) {
                stats.skippedUnknown += 1
            }
            return []
        }

        // Extract text exactly like the native importer: text blocks verbatim, tool_use
        // and tool_result as bounded tags IN PLACE, thinking dropped, unknown made visible.
        guard let extracted = extractText(line.message?["content"]) else { return [] }

        // A user line that is only tool results is the tail of the agent's work,
        // not a user turn — the native importer demotes it to an assistant message.
        let role = (line.type == "assistant" || extracted.onlyToolResult) ? "assistant" : "user"

        if role == "user" {
            var out = closeTurn(completedAt: nil)
            turnIndex += 1
            let tid = "external-import-turn-\(turnIndex)"
            currentTurnId = tid
            currentTurnStartedAt = tsSecs
            if stats.firstUserText == nil { stats.firstUserText = extracted.text }
            stats.turnsEmitted += 1
            responseBytes += extracted.text.utf8.count

            out.append(["timestamp": ts, "type": "event_msg",
                        "payload": ["type": "task_started", "turn_id": tid,
                                    "started_at": tsSecs as Any? ?? NSNull()]])
            out.append(["timestamp": ts, "type": "event_msg",
                        "payload": ["type": "user_message", "message": extracted.text,
                                    "images": [], "local_images": [], "text_elements": []]])
            out.append(["timestamp": ts, "type": "response_item",
                        "payload": ["type": "message", "role": "user",
                                    "content": [["type": "input_text", "text": extracted.text]]]])
            return out
        }

        // Assistant content with no open turn: on a FULL import this is pre-prompt
        // noise (native importer drops it too) — but on an incremental region it is
        // the answer to a previously-synced prompt; dropping it would lose the reply
        // and advance the cursor past it. Open a synthetic continuation turn.
        if currentTurnId == nil {
            guard turnIndex > 0 else { return [] }  // full import from zero: keep native behavior
            turnIndex += 1
            let tid = "external-import-turn-\(turnIndex)"
            currentTurnId = tid
            currentTurnStartedAt = tsSecs
            var out: [[String: Any]] = [["timestamp": ts, "type": "event_msg",
                "payload": ["type": "task_started", "turn_id": tid,
                            "started_at": tsSecs as Any? ?? NSNull()]]]
            responseBytes += extracted.text.utf8.count
            out.append(["timestamp": ts, "type": "event_msg",
                        "payload": ["type": "agent_message", "message": extracted.text]])
            out.append(["timestamp": ts, "type": "response_item",
                        "payload": ["type": "message", "role": "assistant",
                                    "content": [["type": "output_text", "text": extracted.text]]]])
            return out
        }
        responseBytes += extracted.text.utf8.count
        return [
            ["timestamp": ts, "type": "event_msg",
             "payload": ["type": "agent_message", "message": extracted.text]],
            ["timestamp": ts, "type": "response_item",
             "payload": ["type": "message", "role": "assistant",
                         "content": [["type": "output_text", "text": extracted.text]]]],
        ]
    }

    /// Import marker + estimated token count + final task_complete — the native footer.
    func finish() -> [[String: Any]] {
        guard currentTurnId != nil else { return [] }
        let ts = stats.lastTimestamp.isEmpty ? isoNow() : stats.lastTimestamp
        var out: [[String: Any]] = [
            ["timestamp": ts, "type": "event_msg",
             "payload": ["type": "agent_message", "message": "<EXTERNAL SESSION IMPORTED>"]],
        ]
        let tokens = responseBytes / 4                    // native byte→token approximation
        let usage: [String: Any] = ["total_tokens": tokens, "input_tokens": 0, "output_tokens": 0,
                                    "cached_input_tokens": 0, "reasoning_output_tokens": 0]
        out.append(["timestamp": ts, "type": "event_msg",
                    "payload": ["type": "token_count",
                                "info": ["total_token_usage": usage, "last_token_usage": usage,
                                         "model_context_window": NSNull()],
                                "rate_limits": NSNull()]])
        out.append(contentsOf: closeTurn(completedAt: lastTimestampSecs))
        return out
    }

    private func closeTurn(completedAt: Int?) -> [[String: Any]] {
        guard let tid = currentTurnId else { return [] }
        currentTurnId = nil
        let ts = stats.lastTimestamp.isEmpty ? isoNow() : stats.lastTimestamp
        return [["timestamp": ts, "type": "event_msg",
                 "payload": ["type": "task_complete", "turn_id": tid,
                             "last_agent_message": NSNull(),
                             "started_at": currentTurnStartedAt as Any? ?? NSNull(),
                             "completed_at": completedAt as Any? ?? NSNull()]]]
    }

    private struct Extracted {
        let text: String
        let onlyToolResult: Bool
    }

    /// Mirror of the native extract_message_text: string content verbatim; array content
    /// block-by-block with tags; blank result → nil.
    private func extractText(_ content: Any?) -> Extracted? {
        if let s = content as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : Extracted(text: s, onlyToolResult: false)
        }
        guard let items = content as? [[String: Any]] else { return nil }
        var parts: [String] = []
        var onlyToolResult = !items.isEmpty
        for block in items {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String, !t.isEmpty {
                    parts.append(t)
                    onlyToolResult = false
                }
            case "tool_use":
                parts.append(renderToolUse(name: (block["name"] as? String) ?? "unknown",
                                           input: block["input"]))
                onlyToolResult = false
            case "tool_result":
                let isErr = (block["is_error"] as? Bool) ?? false
                parts.append(renderToolResult(flattenContent(block["content"]), isError: isErr))
            case "thinking", .none:
                break
            case .some(let other):
                parts.append("[external unsupported block: \(other)]")
                onlyToolResult = false
            }
        }
        let text = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n\n")
        return text.isEmpty ? nil : Extracted(text: text, onlyToolResult: onlyToolResult)
    }

    var nextTurnIndex: Int { turnIndex }
}

// MARK: - Codex → Claude (incremental emitter, NATIVE tool blocks)

/// Emits native Claude transcript structures: Codex `function_call` becomes a real
/// `tool_use` block and its output a real `tool_result` user line — Claude renders
/// arbitrary tool names natively (that is how MCP tools work), so the mirrored session
/// looks and resumes like a home-grown one. Invariant enforced for API validity: every
/// emitted tool_use is ALWAYS followed by a matching tool_result; a call whose output
/// never arrives gets a synthesized "[no output recorded]" result instead of being
/// dropped (the old text-tag emitter silently lost those).
final class CodexToClaudeEmitter {
    struct Stats {
        var consumedLineCount = 0
        var skippedUnknown = 0
        var lastTimestamp = ""
    }

    private let claudeSessionId: String
    private let codexId: String
    private let cwd: String
    private let model: String
    private var parent: String?
    private var index: Int
    /// Calls awaiting their output, in arrival order: (call_id, tool name, input).
    private var pendingCalls: [(id: String, name: String, input: Any)] = []
    private(set) var stats = Stats()

    // Replay dedup for fork chains: a continuation segment may replay the parent's
    // history before the new turns. Matching is ORDERED and prefix-only: the replay
    // candidate must equal the next expected turn in the already-emitted sequence —
    // a set-based match would swallow legitimate repeats ("ok", "continue") anywhere.
    // Hashes are whitespace-normalized: replayed copies join blocks differently.
    private var emittedUserSequence: [Int] = []
    private var dedupActive = false
    private var replayCursor = 0
    private var skippingReplayedTurn = false

    static func normalizedHash(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").hashValue
    }

    /// Call at the start of each chain segment. `dedupReplay` is true for fork
    /// children being consumed from the beginning.
    func beginSegment(dedupReplay: Bool) {
        dedupActive = dedupReplay
        replayCursor = 0
        skippingReplayedTurn = false
    }

    /// Seeds the replay dedup with the ORDERED user turns already present on the
    /// Claude side (incremental sync consuming a fresh fork child).
    func seedEmittedUserSequence(_ hashes: [Int]) {
        emittedUserSequence = hashes + emittedUserSequence
    }

    /// Codex-injected control payloads that must not bounce between the apps.
    private static let controlPrefixes = ["<environment_context>", "<user_instructions>",
                                          "<permissions", "<recommended_plugins",
                                          "<model_switch", "<EXTERNAL SESSION IMPORTED>"]

    init(claudeSessionId: String, codexId: String, cwd: String, model: String,
         chainTail: String?, startLineIndex: Int) {
        self.claudeSessionId = claudeSessionId
        self.codexId = codexId
        self.cwd = cwd
        self.model = model
        self.parent = chainTail
        self.index = startLineIndex
    }

    var chainTail: String? { parent }
    var nextLineIndex: Int { index }
    /// True while a function_call has no output yet — at EOF this means the turn is
    /// still in flight and an incremental sync should wait rather than fabricate.
    var hasPendingCalls: Bool { !pendingCalls.isEmpty }

    /// Canonical-source rule: user turns from `event_msg user_message` ONLY, assistant
    /// text from `response_item message role:assistant` ONLY — rollouts carry each
    /// message twice and the duplicates must not be emitted twice.
    func feed(_ line: RolloutLine) -> [[String: Any]] {
        stats.consumedLineCount += 1
        let ts = line.timestamp.isEmpty ? isoNow() : line.timestamp
        stats.lastTimestamp = ts

        switch line.type {
        case "event_msg":
            guard line.payloadType == "user_message",
                  let text = line.payload["message"] as? String, !text.isEmpty,
                  !isControl(text) else { return [] }
            let h = Self.normalizedHash(text)
            if dedupActive {
                if replayCursor < emittedUserSequence.count,
                   emittedUserSequence[replayCursor] == h {
                    replayCursor += 1               // matches the expected replayed turn
                    skippingReplayedTurn = true
                    return []
                }
                dedupActive = false                 // sequence diverged: replay is over
            }
            skippingReplayedTurn = false
            emittedUserSequence.append(h)
            // A user turn interrupts any in-flight tool call: settle pairs first.
            var out = flushPendingCalls(ts: ts)
            out.append(emit("user", ["role": "user", "content": text], ts: ts))
            return out

        case "response_item":
            guard !skippingReplayedTurn else { return [] }
            switch line.payloadType {
            case "message":
                guard (line.payload["role"] as? String) == "assistant",
                      let items = line.payload["content"] as? [[String: Any]] else { return [] }
                let text = items.compactMap { item -> String? in
                    guard let t = item["type"] as? String,
                          t == "output_text" || t == "text" else { return nil }
                    return item["text"] as? String
                }.joined(separator: "\n\n")
                guard !text.isEmpty, !isControl(text) else { return [] }
                var out = flushPendingCalls(ts: ts)
                out.append(emit("assistant", assistantEnvelope(
                    content: [["type": "text", "text": text]]), ts: ts))
                return out

            case "function_call", "custom_tool_call":
                let name = (line.payload["name"] as? String) ?? "tool"
                let cid = (line.payload["call_id"] as? String)
                    ?? DeterministicID.uuidV5("call:\(codexId)#\(index)")
                // function_call carries `arguments` (JSON string); custom_tool_call
                // carries `input` (freeform string — the exec script itself).
                pendingCalls.append((id: cid, name: name,
                                     input: parseArguments(line.payload["arguments"]
                                                           ?? line.payload["input"])))
                return []                          // emitted when its output arrives

            case "function_call_output", "custom_tool_call_output":
                let cid = (line.payload["call_id"] as? String) ?? ""
                let output = flattenContent(line.payload["output"])
                if let i = pendingCalls.firstIndex(where: { $0.id == cid }) {
                    let call = pendingCalls.remove(at: i)
                    return emitToolPair(call: call, output: output, isError: false, ts: ts)
                }
                // Output without a recorded call (shouldn't happen): keep the data
                // anyway as a plain assistant note rather than dropping it.
                guard !output.isEmpty else { return [] }
                return [emit("assistant", assistantEnvelope(
                    content: [["type": "text", "text": renderToolResult(output, isError: false)]]),
                    ts: ts)]

            default:
                return []                           // reasoning (encrypted) etc.
            }

        case "session_meta", "turn_context", "compacted", "event", "token_count":
            return []

        default:
            stats.skippedUnknown += 1
            return []
        }
    }

    /// Settle any dangling calls before the stream ends — never leave a tool_use
    /// unpaired (API-invalid) and never drop a recorded call (data loss).
    func finish() -> [[String: Any]] {
        flushPendingCalls(ts: stats.lastTimestamp.isEmpty ? isoNow() : stats.lastTimestamp)
    }

    private func flushPendingCalls(ts: String) -> [[String: Any]] {
        guard !pendingCalls.isEmpty else { return [] }
        var out: [[String: Any]] = []
        for call in pendingCalls {
            out.append(contentsOf: emitToolPair(call: call, output: "[no output recorded]",
                                                isError: false, ts: ts))
        }
        pendingCalls.removeAll()
        return out
    }

    /// One assistant line with the native tool_use block + one user line with the
    /// matching tool_result — exactly the shape Claude Code writes for its own tools.
    private func emitToolPair(call: (id: String, name: String, input: Any),
                              output: String, isError: Bool, ts: String) -> [[String: Any]] {
        let use = emit("assistant", assistantEnvelope(content: [[
            "type": "tool_use",
            "id": call.id,
            "name": call.name,
            "input": call.input,
        ]], stopReason: "tool_use"), ts: ts)

        var resultItem: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": call.id,
            "content": [["type": "text", "text": output]],
        ]
        if isError { resultItem["is_error"] = true }
        var result = emit("user", ["role": "user", "content": [resultItem]], ts: ts)
        result["toolUseResult"] = output
        result["sourceToolUseID"] = call.id
        return [use, result]
    }

    private func isControl(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.controlPrefixes.contains { t.hasPrefix($0) }
    }

    /// Codex stores `arguments` as a JSON string; Claude's tool_use `input` is an object.
    /// Non-JSON strings (custom_tool_call scripts) keep Codex's own field name: `input`.
    private func parseArguments(_ raw: Any?) -> Any {
        if let s = raw as? String {
            if let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                return obj
            }
            return ["input": s]
        }
        return raw ?? [:]
    }

    private func emit(_ type: String, _ message: [String: Any], ts: String) -> [String: Any] {
        index += 1
        let uuid = DeterministicID.lineUuid(codexId: codexId, index: index)
        let line: [String: Any] = [
            "parentUuid": parent as Any? ?? NSNull(),
            "isSidechain": false,
            "type": type,
            "message": message,
            "uuid": uuid,
            "timestamp": ts,
            "sessionId": claudeSessionId,
            "cwd": cwd,
            "version": "2.1.205",
            "gitBranch": "",
            "userType": "external",
            "entrypoint": "claude-desktop",
            "syncOrigin": "codex",
            "syncPairId": codexId,
        ]
        parent = uuid
        return line
    }

    private func assistantEnvelope(content: [[String: Any]],
                                   stopReason: String = "end_turn") -> [String: Any] {
        [
            "id": "msg_css_\(index + 1)",
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": content,
            "stop_reason": stopReason,
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 0, "output_tokens": 0],
        ]
    }
}
