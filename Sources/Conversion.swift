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
        return arr.compactMap { item in
            (item["type"] as? String) == "text" ? item["text"] as? String : nil
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

        // Assistant content before any user turn is dropped (native behavior).
        guard currentTurnId != nil else { return [] }
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

// MARK: - Codex → Claude (incremental emitter)

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
    private var pendingCalls: [String: String] = [:]
    private(set) var stats = Stats()

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
                  let text = line.payload["message"] as? String, !text.isEmpty else { return [] }
            return [emit("user", ["role": "user", "content": text], ts: ts)]

        case "response_item":
            switch line.payloadType {
            case "message":
                guard (line.payload["role"] as? String) == "assistant",
                      let items = line.payload["content"] as? [[String: Any]] else { return [] }
                let text = items.compactMap { item -> String? in
                    guard let t = item["type"] as? String,
                          t == "output_text" || t == "text" else { return nil }
                    return item["text"] as? String
                }.joined(separator: "\n\n")
                guard !text.isEmpty else { return [] }
                return [emit("assistant", assistantEnvelope(text: text), ts: ts)]

            case "function_call", "custom_tool_call":
                let name = (line.payload["name"] as? String) ?? "?"
                let block = renderToolUse(name: "Codex " + name, input: line.payload["arguments"])
                if let cid = line.payload["call_id"] as? String {
                    pendingCalls[cid] = block
                    return []
                }
                return [emit("assistant", assistantEnvelope(text: block), ts: ts)]

            case "function_call_output", "custom_tool_call_output":
                let cid = (line.payload["call_id"] as? String) ?? ""
                let call = pendingCalls.removeValue(forKey: cid) ?? "⏺ Codex tool call"
                let out = flattenContent(line.payload["output"])
                let text = call + "\n" + renderToolResult(out, isError: false)
                return [emit("assistant", assistantEnvelope(text: text), ts: ts)]

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

    private func assistantEnvelope(text: String) -> [String: Any] {
        [
            "id": "msg_css_\(index + 1)",
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [["type": "text", "text": text]],
            "stop_reason": "end_turn",
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 0, "output_tokens": 0],
        ]
    }
}
