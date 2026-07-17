import SwiftUI
import AppKit

// MARK: - Paths

let HOME = FileManager.default.homeDirectoryForCurrentUser
let SUPPORT = HOME.appending(path: "Library/Application Support/Claude")
let BASE = SUPPORT.appending(path: "claude-code-sessions")
let REGISTRY = SUPPORT.appending(path: "ant-device-registry.json")
let CLAUDE_HOME = HOME.appending(path: ".claude")
let BACKUP_PREFIX = "claude-code-sessions.backup-"

/// Fields that reference MCP-server UUIDs registered per account. A session opened under an
/// account that cannot resolve those UUIDs gets them reset to empty, so an incoming empty
/// value must never overwrite a populated one.
let MCP_FIELDS = ["remoteMcpServersConfig", "enabledMcpTools"]

/// Not a session: it belongs to whichever account scheduled the tasks.
let SKIP_FILES: Set<String> = ["scheduled-tasks.json"]

// MARK: - JSON value helpers

func num(_ v: Any?) -> Int {
    if let n = v as? NSNumber { return n.intValue }
    if let s = v as? String, let i = Int(s) { return i }
    return 0
}

func isEmptyVal(_ v: Any?) -> Bool {
    guard let v, !(v is NSNull) else { return true }
    if let s = v as? String { return s.isEmpty }
    if let a = v as? [Any] { return a.isEmpty }
    if let d = v as? [String: Any] { return d.isEmpty }
    return false
}

func sameDict(_ a: [String: Any], _ b: [String: Any]) -> Bool {
    NSDictionary(dictionary: a).isEqual(to: b)
}

func fmtDate(_ ms: Int) -> String {
    guard ms > 0 else { return "—" }
    let f = DateFormatter()
    f.dateFormat = "d MMM yyyy, HH:mm"
    f.locale = Locale(identifier: "en_US")
    return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

func short(_ uuid: String) -> String { String(uuid.prefix(8)) }

// MARK: - Model

struct Copy {
    let path: URL
    let data: [String: Any]
    let activity: Int
    let focused: Int
    let mtime: Double

    /// The comparison is a tuple because some sessions only differ in `lastFocusedAt`: with
    /// `lastActivityAt` alone they would tie and the winner would be arbitrary.
    func beats(_ o: Copy) -> Bool {
        if activity != o.activity { return activity > o.activity }
        if focused != o.focused { return focused > o.focused }
        return mtime > o.mtime
    }
}

enum Status: String { case synced, differs, missing }

struct SessionRow: Identifiable {
    let id: String
    let title: String
    let cwd: String
    let lastActivity: Int
    let accounts: [String]
    let winner: String
    let status: Status
    let orphan: Bool
}

struct AccountRow: Identifiable {
    let id: String
    let sessions: Int
    let lastActivity: Int
    let device: String
}

struct Action {
    let file: String
    let title: String
    let create: Bool
    let from: String
    let to: String
    let path: URL
    let content: [String: Any]
}

struct Failure: Identifiable {
    let id = UUID()
    let session: String
    let account: String
    let reason: String
}

struct SyncReport {
    var backup: URL?
    var removed: [String] = []
    var created = 0
    var updated = 0
    var failed: [Failure] = []
    var fatal: FatalError?
    var ok: Bool { fatal == nil && failed.isEmpty }
}

/// Errors that stop the sync before anything is written. The text is what the user reads:
/// no Cocoa `localizedDescription`, which here would produce sentences like
/// "The file “x” couldn’t be opened because you don’t have permission to view it."
enum FatalError: Identifiable {
    case baseMissing
    case backupFailed(String)

    var id: String { title }

    var title: String {
        switch self {
        case .baseMissing: "No Claude Code data on this Mac"
        case .backupFailed: "Backup failed — nothing was changed"
        }
    }

    var detail: String {
        switch self {
        case .baseMissing:
            "The claude-code-sessions folder does not exist. Open Claude Code at least once from the Claude app, then try again."
        case .backupFailed(let why):
            "The safety backup could not be created, so I stopped before touching any session.\n\nTechnical cause: \(why)"
        }
    }
}

/// Turns a filesystem error into a readable cause.
func plainReason(_ error: Error) -> String {
    let ns = error as NSError
    switch ns.code {
    case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
        return "insufficient permissions"
    case NSFileWriteOutOfSpaceError:
        return "disk is full"
    case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
        return "file or folder not found"
    case NSFileWriteFileExistsError:
        return "file already exists"
    default:
        return ns.localizedFailureReason ?? ns.localizedDescription
    }
}

// MARK: - Disk scan

func discoverAccounts() -> [String: URL] {
    let fm = FileManager.default
    var out: [String: URL] = [:]
    guard let entries = try? fm.contentsOfDirectory(atPath: BASE.path) else { return out }
    for entry in entries.sorted() {
        let accDir = BASE.appending(path: entry)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: accDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
        guard let inner = try? fm.contentsOfDirectory(atPath: accDir.path) else { continue }
        let dirs = inner.map { accDir.appending(path: $0) }.filter {
            var d: ObjCBool = false
            return fm.fileExists(atPath: $0.path, isDirectory: &d) && d.boolValue
        }
        guard !dirs.isEmpty else { continue }
        // An account may hold several org dirs; the sidebar reads the one with the most sessions.
        let primary = dirs.max { sessionFiles(in: $0).count < sessionFiles(in: $1).count }!
        out[entry] = primary
    }
    return out
}

func sessionFiles(in dir: URL) -> [URL] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
    return names
        .filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") && !SKIP_FILES.contains($0) }
        .map { dir.appending(path: $0) }
}

func readJSON(_ url: URL) -> [String: Any]? {
    guard let d = try? Data(contentsOf: url),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return o
}

/// cliSessionId of sessions that still have a transcript on disk.
func transcriptIDs() -> Set<String> {
    var out: Set<String> = []
    guard let e = FileManager.default.enumerator(atPath: CLAUDE_HOME.path) else { return out }
    for case let p as String in e where p.hasSuffix(".jsonl") {
        out.insert((p as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: ""))
    }
    return out
}

func deviceRegistry() -> [String: String] {
    (readJSON(REGISTRY) as? [String: String]) ?? [:]
}

func buildIndex(_ accounts: [String: URL]) -> [String: [String: Copy]] {
    var index: [String: [String: Copy]] = [:]
    for (acc, dir) in accounts {
        for url in sessionFiles(in: dir) {
            guard let data = readJSON(url) else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let copy = Copy(path: url, data: data,
                            activity: num(data["lastActivityAt"]),
                            focused: num(data["lastFocusedAt"]), mtime: mtime)
            index[url.lastPathComponent, default: [:]][acc] = copy
        }
    }
    return index
}

// MARK: - Merge and plan

func merge(winner: [String: Any], dest: [String: Any]?) -> [String: Any] {
    var out = winner
    guard let dest else { return out }
    for f in MCP_FIELDS where isEmptyVal(out[f]) && !isEmptyVal(dest[f]) {
        out[f] = dest[f]
    }
    return out
}

func makePlan(_ accounts: [String: URL], _ index: [String: [String: Copy]]) -> [Action] {
    var actions: [Action] = []
    for (file, copies) in index {
        guard let winAcc = copies.max(by: { $1.value.beats($0.value) })?.key else { continue }
        let winner = copies[winAcc]!.data
        for (acc, dir) in accounts {
            let dest = copies[acc]?.data
            let target = merge(winner: winner, dest: dest)
            if let dest, sameDict(dest, target) { continue }
            actions.append(Action(
                file: file,
                title: (winner["title"] as? String) ?? "(senza titolo)",
                create: dest == nil, from: winAcc, to: acc,
                path: dir.appending(path: file), content: target))
        }
    }
    return actions.sorted { $0.title < $1.title }
}

// MARK: - Backup and sync

func purgeBackups() throws -> [String] {
    let fm = FileManager.default
    var removed: [String] = []
    for entry in (try? fm.contentsOfDirectory(atPath: SUPPORT.path)) ?? [] {
        guard entry.hasPrefix(BACKUP_PREFIX) else { continue }
        let path = SUPPORT.appending(path: entry)
        // Double-check: never remove anything outside the backup namespace.
        guard path.path.hasPrefix(BASE.path + ".backup-") else { continue }
        try fm.removeItem(at: path)
        removed.append(entry)
    }
    return removed
}

func runSync() -> SyncReport {
    var report = SyncReport()
    let fm = FileManager.default
    guard fm.fileExists(atPath: BASE.path) else {
        report.fatal = .baseMissing
        return report
    }
    do {
        report.removed = try purgeBackups()
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let dest = URL(filePath: BASE.path + ".backup-" + f.string(from: Date()))
        try fm.copyItem(at: BASE, to: dest)
        report.backup = dest
    } catch {
        report.fatal = .backupFailed(plainReason(error))
        return report
    }

    let accounts = discoverAccounts()
    for a in makePlan(accounts, buildIndex(accounts)) {
        do {
            let data = try JSONSerialization.data(withJSONObject: a.content, options: [.prettyPrinted])
            try data.write(to: a.path, options: .atomic)
            if a.create { report.created += 1 } else { report.updated += 1 }
        } catch {
            report.failed.append(Failure(session: a.title, account: short(a.to),
                                         reason: plainReason(error)))
        }
    }
    return report
}

func claudeIsRunning() -> Bool {
    !NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier == "com.anthropic.claudefordesktop" || $0.localizedName == "Claude"
    }.isEmpty
}

// MARK: - Store

@MainActor final class Store: ObservableObject {
    @Published var accounts: [AccountRow] = []
    @Published var sessions: [SessionRow] = []
    @Published var pending: [Action] = []
    @Published var busy = false
    @Published var claudeRunning = false
    @Published var report: SyncReport?

    var synced: Int { sessions.filter { $0.status == .synced }.count }
    var differs: Int { sessions.filter { $0.status == .differs }.count }
    var missing: Int { sessions.filter { $0.status == .missing }.count }
    var orphans: Int { sessions.filter(\.orphan).count }
    var activeAccount: String? { accounts.first?.id }

    func reload() {
        let accs = discoverAccounts()
        let index = buildIndex(accs)
        let have = transcriptIDs()
        let reg = deviceRegistry()
        claudeRunning = claudeIsRunning()

        accounts = accs.map { acc, dir in
            let files = sessionFiles(in: dir)
            let last = files.compactMap { readJSON($0) }.map { num($0["lastActivityAt"]) }.max() ?? 0
            return AccountRow(id: acc, sessions: files.count, lastActivity: last,
                              device: reg[acc] ?? "—")
        }.sorted { $0.lastActivity > $1.lastActivity }

        let n = accs.count
        sessions = index.map { file, copies in
            let winAcc = copies.max { $1.value.beats($0.value) }!.key
            let winner = copies[winAcc]!.data
            let present = copies.keys.sorted()
            let status: Status
            if present.count < n { status = .missing }
            else if present.contains(where: { !sameDict(copies[$0]!.data, copies[present[0]]!.data) }) { status = .differs }
            else { status = .synced }
            return SessionRow(
                id: file, title: (winner["title"] as? String) ?? "(senza titolo)",
                cwd: (winner["cwd"] as? String) ?? "—",
                lastActivity: num(winner["lastActivityAt"]),
                accounts: present.map(short), winner: short(winAcc), status: status,
                orphan: !have.contains((winner["cliSessionId"] as? String) ?? ""))
        }.sorted { $0.lastActivity > $1.lastActivity }

        pending = makePlan(accs, index)
    }

    func sync() {
        guard !busy else { return }
        busy = true
        Task.detached {
            let r = runSync()
            await MainActor.run {
                self.busy = false
                self.report = r
                self.reload()
            }
        }
    }
}

