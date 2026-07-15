import Foundation

// Minimal JSON-RPC client for `codex app-server` (stdio). Used for operations where
// the sqlite rows are NOT the source of truth: archiving a thread by writing
// archived=1 directly gets reverted by the app's engine on its next launch — the
// thread/archive RPC is the official, durable path (verified across app restarts).

enum AppServerRPC {

    private static var codexBinary: String? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            NSString(string: "~/.local/bin/codex").expandingTildeInPath,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Archives the given thread ids. Returns how many the server acknowledged.
    static func archiveThreads(_ ids: [String]) -> Int {
        guard !ids.isEmpty, let bin = codexBinary else { return 0 }

        let proc = Process()
        proc.executableURL = URL(filePath: bin)
        proc.arguments = ["app-server"]
        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return 0 }
        defer { proc.terminate() }

        var buffer = Data()
        /// Reads lines until the response with `id` arrives (notifications are skipped).
        func waitFor(id: Int, deadline: TimeInterval = 20) -> Bool {
            let until = Date().addingTimeInterval(deadline)
            while Date() < until {
                if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer.prefix(upTo: nl)
                    buffer.removeSubrange(...nl)
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line))
                            as? [String: Any] else { continue }
                    if (obj["id"] as? Int) == id { return obj["result"] != nil }
                    continue
                }
                let chunk = outPipe.fileHandleForReading.availableData
                if chunk.isEmpty { return false }        // server exited
                buffer.append(chunk)
            }
            return false
        }
        func send(_ obj: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            data.append(UInt8(ascii: "\n"))
            inPipe.fileHandleForWriting.write(data)
        }

        send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": ["clientInfo": ["name": "claude_session_sync",
                                        "title": "CSS", "version": "2.0"]]])
        guard waitFor(id: 1) else { return 0 }
        send(["jsonrpc": "2.0", "method": "initialized", "params": [:]])

        var done = 0
        for (i, tid) in ids.enumerated() {
            let reqId = 10 + i
            send(["jsonrpc": "2.0", "id": reqId, "method": "thread/archive",
                  "params": ["threadId": tid]])
            if waitFor(id: reqId) { done += 1 }
        }
        return done
    }
}
