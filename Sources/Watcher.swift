import Foundation
import CoreServices

// MARK: - SyncGate: self-event suppression
// The engine writes into the very trees the watcher watches. Without suppression the
// app would ping-pong on its own writes. kFSEventStreamCreateFlagIgnoreSelf is the
// first line but is unreliable with atomic (write-temp + rename) writes, so the gate
// is the guarantee.

actor SyncGate {
    private var suppressed: [String: Date] = [:]        // canonical path → expiry
    private var globalPauseUntil = Date.distantPast

    /// FSEvents delivery can lag by up to the stream latency; tokens therefore expire
    /// on a timed grace window AFTER the write finishes — never at endWrites itself.
    private let grace: TimeInterval = 2.0 + 5.0

    func beginWrites(_ paths: [String]) {
        for p in paths { suppressed[canon(p)] = .distantFuture }
    }

    func endWrites(_ paths: [String]) {
        let expiry = Date().addingTimeInterval(grace)
        for p in paths { suppressed[canon(p)] = expiry }
    }

    func pauseAll(seconds: TimeInterval) {
        globalPauseUntil = max(globalPauseUntil, Date().addingTimeInterval(seconds))
    }

    func isSuppressed(_ path: String) -> Bool {
        if Date() < globalPauseUntil { return true }
        let key = canon(path)
        guard let expiry = suppressed[key] else { return false }
        if Date() >= expiry {
            suppressed[key] = nil
            return false
        }
        return true
    }

    private func canon(_ p: String) -> String {
        URL(filePath: p).standardizedFileURL.path
    }
}

// MARK: - Debouncer: per-pair quiescence timers

actor Debouncer {
    private var timers: [String: Task<Void, Never>] = [:]
    private var quiescence: Duration = .seconds(20)

    func setQuiescence(seconds: Double) {
        quiescence = .seconds(max(5, min(seconds, 120)))
    }

    /// Trailing debounce: every event re-arms the timer; it fires only after the
    /// transcript has been quiet for the full window (= "finished replying").
    func bump(key: String, fire: @escaping @Sendable (String) -> Void) {
        timers[key]?.cancel()
        let q = quiescence
        timers[key] = Task {
            try? await Task.sleep(for: q)
            guard !Task.isCancelled else { return }
            fire(key)
        }
    }

    func cancelAll() {
        for (_, t) in timers { t.cancel() }
        timers.removeAll()
    }
}

// MARK: - FSEvents watcher over both session trees

final class SessionWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "css.watcher", qos: .utility)
    private var onEvent: (@Sendable (String) -> Void)?
    private var onOverflow: (@Sendable () -> Void)?
    private var paused = false

    var isRunning: Bool { stream != nil }

    func start(roots: [URL],
               onEvent: @escaping @Sendable (String) -> Void,
               onOverflow: @escaping @Sendable () -> Void) {
        stop()
        self.onEvent = onEvent
        self.onOverflow = onOverflow

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<SessionWatcher>.fromOpaque(info).takeUnretainedValue()
            guard !watcher.paused else { return }
            guard let pathArray = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            for i in 0..<count {
                let f = flags[i]
                if f & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                    watcher.onOverflow?()                 // kernel dropped events
                    continue
                }
                let path = pathArray[i]
                guard path.hasSuffix(".jsonl") else { continue }
                watcher.onEvent?(path)
            }
        }

        let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            roots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,                                          // latency: batched, battery-friendly
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagIgnoreSelf))
        guard let s else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func setPaused(_ p: Bool) { paused = p }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
