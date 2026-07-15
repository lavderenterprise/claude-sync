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

private let toolPayloadCap = 4096

func renderToolUse(name: String, input: Any?) -> String {
    var body = ""
    if let input, JSONSerialization.isValidJSONObject(input),
       let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        body = s
    } else if let s = input as? String {
        body = s
    }
    if body.count > toolPayloadCap { body = String(body.prefix(toolPayloadCap)) + "\n… (truncated)" }
    return "⏺ Tool: \(name)" + (body.isEmpty ? "" : "\n" + body)
}

func renderToolResult(_ text: String, isError: Bool) -> String {
    var t = text
    if t.count > toolPayloadCap { t = String(t.prefix(toolPayloadCap)) + "… (truncated)" }
    return "  ⎿ " + (isError ? "(error) " : "") + t
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

/// Feed Claude lines one at a time; rollout lines come out. Two-phase by design:
/// callers first stream the region once through `collectToolResults`, then stream it
/// again through `feed` — tool results arrive as *user* lines and must be attached to
/// the assistant blocks that invoked them.
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
    private let turnTemplate: [String: Any]
    private let toolResults: [String: String]
    private var turnIndex: Int
    private var currentTurnId: String?
    private var lastAgentText = ""
    private(set) var stats = Stats()

    init(codexId: String, cwd: String, turnTemplate: [String: Any],
         toolResults: [String: String], startTurnIndex: Int) {
        self.codexId = codexId
        self.cwd = cwd
        self.turnTemplate = turnTemplate
        self.toolResults = toolResults
        self.turnIndex = startTurnIndex
    }

    static func collectToolResults(path: String, from offset: Int64) throws -> [String: String] {
        var out: [String: String] = [:]
        _ = try streamJSONL(path: path, from: offset) { dict in
            guard (dict["type"] as? String) == "user",
                  (dict["isSidechain"] as? Bool) != true,
                  let message = dict["message"] as? [String: Any],
                  let items = message["content"] as? [[String: Any]] else { return }
            for item in items where (item["type"] as? String) == "tool_result" {
                guard let id = item["tool_use_id"] as? String else { continue }
                let isErr = (item["is_error"] as? Bool) ?? false
                out[id] = renderToolResult(flattenContent(item["content"]), isError: isErr)
            }
        }
        return out
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

        guard !line.isSidechain else { return [] }

        switch line.type {
        case "user":
            guard !line.isMeta,
                  (line.raw["isCompactSummary"] as? Bool) != true,
                  (line.raw["isVisibleInTranscriptOnly"] as? Bool) != true else { return [] }
            let content = line.message?["content"]
            var text = ""
            if let s = content as? String {
                text = s
            } else if let items = content as? [[String: Any]] {
                // Tool-result-only user lines are plumbing, not a user turn.
                let texts = items.filter { ($0["type"] as? String) == "text" }
                guard !texts.isEmpty else { return [] }
                text = texts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            guard !text.isEmpty else { return [] }

            var out = closeTurn(at: ts)
            turnIndex += 1
            let tid = DeterministicID.turnId(codexId: codexId, index: turnIndex)
            currentTurnId = tid
            if stats.firstUserText == nil { stats.firstUserText = text }
            stats.turnsEmitted += 1

            var turn = turnTemplate
            turn["turn_id"] = tid
            turn["cwd"] = cwd
            turn["workspace_roots"] = [cwd]
            if var sp = turn["sandbox_policy"] as? [String: Any], sp["writable_roots"] != nil {
                sp["writable_roots"] = [cwd]
                turn["sandbox_policy"] = sp
            }
            out.append(["timestamp": ts, "type": "turn_context", "payload": turn])
            out.append(["timestamp": ts, "type": "event_msg",
                        "payload": ["type": "task_started", "turn_id": tid]])
            out.append(["timestamp": ts, "type": "event_msg",
                        "payload": ["type": "user_message", "message": text,
                                    "images": [], "local_images": [], "text_elements": []]])
            out.append(["timestamp": ts, "type": "response_item",
                        "payload": ["type": "message", "role": "user",
                                    "content": [["type": "input_text", "text": text]]]])
            return out

        case "assistant":
            guard let items = line.message?["content"] as? [[String: Any]] else { return [] }
            var blocks: [String] = []
            for item in items {
                switch item["type"] as? String {
                case "text":
                    if let t = item["text"] as? String, !t.isEmpty { blocks.append(t) }
                case "tool_use":
                    let name = (item["name"] as? String) ?? "?"
                    blocks.append(renderToolUse(name: name, input: item["input"]))
                    if let id = item["id"] as? String, let res = toolResults[id] {
                        blocks.append(res)
                    }
                default:
                    break                           // thinking, fallback, unknown → skipped
                }
            }
            guard !blocks.isEmpty else { return [] }
            let text = blocks.joined(separator: "\n\n")
            lastAgentText = text
            return [
                ["timestamp": ts, "type": "response_item",
                 "payload": ["type": "message", "role": "assistant",
                             "content": [["type": "output_text", "text": text]]]],
                ["timestamp": ts, "type": "event_msg",
                 "payload": ["type": "agent_message", "message": text]],
            ]

        case "system", "attachment", "queue-operation", "last-prompt", "mode",
             "pr-link", "ai-title", "custom-title", "file":
            return []                               // known non-conversation lines

        default:
            stats.skippedUnknown += 1               // schema drift: visible, never fatal
            return []
        }
    }

    func finish() -> [[String: Any]] {
        closeTurn(at: stats.lastTimestamp.isEmpty ? isoNow() : stats.lastTimestamp)
    }

    private func closeTurn(at ts: String) -> [[String: Any]] {
        guard let tid = currentTurnId else { return [] }
        currentTurnId = nil
        let text = lastAgentText
        lastAgentText = ""
        return [["timestamp": ts, "type": "event_msg",
                 "payload": ["type": "task_complete", "turn_id": tid,
                             "last_agent_message": text]]]
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
