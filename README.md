# Claude Session Sync

A tiny native macOS app that shows **every Claude account used on your Mac** and **all the Claude Code sessions inside each one**, highlights what has drifted between accounts, and — with one click — backs everything up and reconciles the accounts so no session disappears when you switch login.

No dependencies, no Electron, no browser. A single SwiftUI binary built against the Xcode toolchain.

---

## The problem it solves

The Claude desktop app stores its Claude Code **session index** partitioned per account:

```
~/Library/Application Support/Claude/claude-code-sessions/
├── <accountUuidA>/<orgUuid>/local_*.json   ← account A: 101 sessions
└── <accountUuidB>/<orgUuid>/local_*.json   ← account B: 1 session
```

When you switch login, the app reads **only the folder of the account you are signed into**, so every session recorded under the other account vanishes from the sidebar. This is documented and [closed as "not planned"](https://github.com/anthropics/claude-code/issues/48511) — it is the intended behavior, not a bug that will be fixed.

The important part: **the conversations themselves are not lost.** The actual transcripts live in a *non*-partitioned location:

```
~/.claude/projects/<encoded-path>/<cliSessionId>.jsonl
```

That's why the CLI (`claude --resume`) can always see every session regardless of account. Only the small `local_*.json` **index files** — title, sort order, last-opened timestamp, MCP config — are partitioned. So the fix is to reconcile the index across accounts, which is exactly what this tool does.

---

## What it does

- **Discovers every account** under `claude-code-sessions/` and lists them with their UUID, session count, and last activity. The most-recently-active account is flagged **Active**.
- **Lists every session** across all accounts, with title, working directory, which accounts it exists in, which copy is the most recent, and a per-session status: `in sync`, `diverging`, or `missing`.
- **Flags orphaned sessions** — those whose transcript has been removed by Claude's automatic cleanup. They still appear in the sidebar but open empty, and no sync can bring them back. The tool marks them clearly so you know the difference between "out of sync" and "gone".
- **Previews the sync plan** before touching anything — a list of exactly which sessions will be created or updated, and in which direction.
- **Backs up and syncs in one click**: deletes previous backups, makes a fresh dated backup of the whole `claude-code-sessions` folder, then writes the winning copy of each session into every account.

Nothing is written until you open the preview and press **Back up and apply**.

---

## How reconciliation works

For every session that exists in more than one account, the tool picks a **winner** and copies it to the others.

### Choosing the winner

The winner is the copy with the highest `(lastActivityAt, lastFocusedAt, mtime)` tuple, compared in that order.

It has to be a tuple, not just `lastActivityAt`: some sessions differ **only** in `lastFocusedAt` (you re-opened a session without sending a message). With `lastActivityAt` alone those would tie and the winner would be arbitrary — the tuple breaks the tie deterministically.

### Preserving per-account MCP config

Two fields — `remoteMcpServersConfig` and `enabledMcpTools` — reference MCP-server UUIDs that are registered **per account**. When you open a session under an account that can't resolve those UUIDs (e.g. a Figma server registered on the other account), the app resets them to empty.

If the winning copy has these fields empty but the destination copy still has them populated, the tool **keeps the destination's value**. Without this rule a naïve sync would wipe still-valid MCP configuration. Only genuinely account-scoped fields are protected this way; everything else follows the winner.

### What is never touched

`scheduled-tasks.json` is not a session — it belongs to whichever account scheduled the tasks — and is always skipped.

### Safety

- Backups are made **before** any write. Previous `claude-code-sessions.backup-*` folders are deleted and one fresh, complete, timestamped copy is created. The delete step double-checks the path prefix so it can never remove anything outside the backup namespace.
- Every session file is written **atomically** (`Data.write(options: .atomic)`), so a crash mid-write can never leave a truncated JSON file.
- If the backup fails for any reason, the sync **aborts before writing** and reports it — your sessions are left untouched.

---

## Important notes

- **Quit and reopen the Claude app after syncing.** The index is only re-read on launch, so a running Claude app won't show the changes until you restart it — and may even overwrite the files you just synced. The tool warns you when Claude is open.
- **Orphaned sessions cannot be recovered.** The tool aligns the index; it cannot recreate a transcript that automatic cleanup already deleted from `~/.claude/projects`. Orphans are marked so you're not surprised when they open empty.
- **Divergence is one-directional and continuous.** The moment you use a session under one account, that account's copy pulls ahead. Re-run the sync before switching accounts if you want both sides current. There is no automatic background sync — this is a deliberate, on-demand tool.

---

## Build

Requires the Xcode command-line Swift toolchain (`swiftc`). Apple Silicon.

```sh
./build.sh
open ClaudeSessionSync.app
```

`build.sh` compiles the two Swift sources into a proper `.app` bundle with an `Info.plist`, then ad-hoc code-signs it (without a signature macOS kills the app on launch on Apple Silicon).

### Project layout

```
Sources/ClaudeSessionSync.swift   Core logic — disk scan, model, winner rule, merge, backup, sync
Sources/UI.swift                  SwiftUI views — stats, account cards, table, plan/result sheets
build.sh                          Bundles and signs ClaudeSessionSync.app
```

The core logic is fully separated from the UI. Everything that reads or writes disk lives in `ClaudeSessionSync.swift`; `UI.swift` only presents it.

---

## Paths it reads

| Path | Purpose |
| --- | --- |
| `~/Library/Application Support/Claude/claude-code-sessions/` | Per-account session index (read + written) |
| `~/Library/Application Support/Claude/ant-device-registry.json` | Per-account device registration (read only) |
| `~/.claude/**/*.jsonl` | Transcripts, to detect orphaned sessions (read only) |
| `~/Library/Application Support/Claude/claude-code-sessions.backup-*` | Backups the tool creates (written) |

The tool never reads or transmits transcript **contents** — it only checks whether a transcript file exists.

---

## License

MIT — do whatever you want. No warranty; it edits files under `Application Support`, and while it backs up first, you run it at your own risk.
