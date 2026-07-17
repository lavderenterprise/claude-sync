import Foundation
import CoreServices

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
    // Read on the FSEvents queue, written from the main thread: lock-protected —
    // an unsynchronized Bool here is a data race, and a stale read lets a self-write
    // event through the pause.
    private let pausedLock = NSLock()
    private var _pauseCount = 0
    var isPausedNow: Bool {
        pausedLock.lock(); defer { pausedLock.unlock() }
        return _pauseCount > 0
    }
    /// Counted pause: overlapping runs each balance their own begin/end — a single
    /// Bool let run A's delayed unpause fire mid-run-B.
    func beginPause() { pausedLock.lock(); _pauseCount += 1; pausedLock.unlock() }
    func endPause() { pausedLock.lock(); _pauseCount = max(0, _pauseCount - 1); pausedLock.unlock() }

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
            guard !watcher.isPausedNow else { return }
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

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        onEvent = nil               // callbacks racing invalidation must find nothing
        onOverflow = nil
    }

    deinit { stop() }
}
