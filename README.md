# Claude Session Sync

A native macOS app that keeps your AI coding sessions where you expect them — across **Claude accounts** and across **assistants**:

- **Accounts** — shows every Claude account used on your Mac and all the Claude Code sessions inside each one, highlights what has drifted, and reconciles the account indexes with one click so no session disappears when you switch login.
- **Codex** — bidirectional sync of chats between **Claude Code and OpenAI Codex** (the ChatGPT desktop app): full-history mirror both ways, incremental two-way updates, conflict handling, and an opt-in **auto-sync** that mirrors a chat to the other app the moment it finishes receiving a reply.
- **Menu bar widget** — one-click sync with a live badge counting the chats waiting to sync; the app keeps working in the background with the window closed (optional launch at login).

No dependencies, no Electron, no browser. A single SwiftUI binary built against the Xcode toolchain (plus the system `libsqlite3`).

---

## Codex sync (Claude Code ⇄ OpenAI Codex)

The Codex tab pairs every Claude Code session with an OpenAI Codex thread and keeps both sides current:

- **Full-history mirror**: every Claude session becomes a resumable Codex thread (rollout JSONL + `threads` row in `state_5.sqlite` + `session_index.jsonl`) and every Codex thread becomes a resumable Claude session (transcript with a valid uuid chain + desktop index entry). Verified end-to-end: `codex exec resume` and Claude both load the imported counterparts.
- **Incremental two-way sync**: byte-offset cursors per side detect exactly what advanced; only the new region is converted and appended. Deterministic IDs make every operation idempotent — re-running never duplicates.
- **Conversion fidelity**: Claude → Codex replicates OpenAI's own (currently server-disabled) `/import` renderer bit for bit — bounded `[external_agent_tool_call]` / `[external_agent_tool_result]` tags with key fields extracted, readable turn ids, `<EXTERNAL SESSION IMPORTED>` footer and token estimate (derived from the `codex-rs/external-agent-migration` source). Codex → Claude goes one better: `function_call`s and `custom_tool_call`s (both payload generations, string or typed-block outputs) become **native `tool_use`/`tool_result` blocks** (Claude renders arbitrary tool names natively — that's how MCP tools work), with every call guaranteed a paired result: missing outputs are synthesized on full imports, and incremental syncs wait when a call is still in flight. Claude `thinking` and Codex encrypted reasoning are skipped by design; Codex-injected control payloads are filtered so they never bounce between apps.
- **Turn-aware, not just timer-aware**: a session whose grown side is mid-turn shows as `working…` — excluded from the badge, from Sync all and from auto-sync. "Mid-turn" is semantic, read from the file tail (an unanswered prompt, a pending tool result, an open `task_started`), because a long-running tool keeps the file silent while the turn is wide open; a 10-minute staleness cap releases abandoned turns.
- **Conflicts**: if both sides advanced since the last sync, the pair is flagged and counted in the menu bar badge — never auto-resolved. You pick the winning side; the losing side's turns stay untouched in their own transcript (recorded as skipped in the ledger).
- **Auto-sync (opt-in)**: one FSEvents stream watches both session trees; a per-session quiet-period timer (default 20 s) fires when a reply has finished landing, and the pair syncs by itself. Self-written events are suppressed so the engine never reacts to its own writes.
- **Integrity doctor (Verify)**: read-only structural check of every pair — uuid chains of synced lines, tool_use/tool_result pairing (in-flight tails tolerated, native compaction/forks respected), rollout `session_meta` identity and turn balance, ledger-cursor coherence. Broken sessions surface before ping-pong syncing can amplify them.
- **ChatGPT UI integration**: imports register each thread's folder in the app's Projects list and write the thread→folder hints its "organize by project" view actually reads (with no trust granted — Codex still asks per folder). Account-switch relics (the same session forked across accounts, the original stranded in an inactive account) get their mirror thread auto-archived via the official `thread/archive` RPC — writing `archived=1` to sqlite directly gets reverted by the app; the ledger follows the rollout when archiving moves it to `archived_sessions/`.
- **Safety**: a timestamped backup (Codex DB via `VACUUM INTO` with the Online Backup API as fallback, indexes, ledger, Claude session index) precedes every writing run; transcripts are append-only with per-file `.css-bak`; every append is guarded by a fsync'd write-intent that recovers cleanly after a crash; a schema-version guard disables Codex-side writes if the (alpha) ChatGPT app changes its database format.

State lives in `~/Library/Application Support/ClaudeSessionSync/` (`codex-links.json` ledger + `backups/`).

---

## The problem it solves (Accounts tab)

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
Sources/App.swift                 Scene, AppDelegate (background lifecycle), TabView shell
Sources/AppModel.swift            App-scoped root model: watcher wiring, auto-sync coordinator, badge
Sources/ClaudeSessionSync.swift   Accounts engine — index scan, winner rule, merge, backup, sync
Sources/UI.swift                  Accounts tab views (stats, cards, table, plan/result sheets)
Sources/CodexModel.swift          Pair model, states, sync report, user-facing fatal errors
Sources/LinkStore.swift           Pair ledger: side cursors, write intents, atomic tmp+bak persistence
Sources/ClaudeStore.swift         Claude side: streaming JSONL parser/writers, turn-in-flight detection
Sources/CodexStoreIO.swift        Codex side: rollout I/O, threads-DB writers, templates, UI-state top-ups
Sources/Conversion.swift          Both converters (native-importer-parity + native tool blocks), deterministic IDs
Sources/SyncEngine.swift          Scan, change detection, executors, conflicts, mass import, doctor, backups
Sources/SQLiteLite.swift          Zero-dependency SQLite wrapper + live-DB backup (VACUUM INTO / backup API)
Sources/AppServerRPC.swift        JSON-RPC client for `codex app-server` (durable thread archiving)
Sources/Watcher.swift             FSEvents stream, quiescence debouncer, self-event suppression gate
Sources/MenuBar.swift             Menu bar extra: badge label + quick-sync menu
Sources/CodexStore.swift          Codex tab store (UI state, async operation dispatch)
Sources/CodexUI.swift             Codex tab views: pair table, plan/resolve/result/verify sheets
Sources/SettingsUI.swift          Settings tab: auto-sync, quiet period, menu bar, login item
Icon/AppIcon.icon                 App icon, authored in Apple Icon Composer
build.sh                          Compiles the icon (actool), bundles, and signs ClaudeSessionSync.app
```

Engine code never imports SwiftUI views and vice versa: everything that touches disk lives in the store/engine files; the `*UI.swift` files only present it.

### App icon

The icon is authored in **Apple Icon Composer** and lives at `Icon/AppIcon.icon`. At build time `build.sh` runs `actool` — Apple's own asset compiler — to render it into `Assets.car` (the Liquid Glass icon macOS 26 draws natively) plus a flat `AppIcon.icns` fallback for older systems. The icon is never hand-converted; to change it, edit the `.icon` bundle in Icon Composer and rebuild.

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
