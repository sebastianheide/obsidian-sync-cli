# obsidian-agent-sync

Headless Obsidian vault sync for AI agents and servers. Lets a machine without a display read and write your Obsidian notes and have every change flow instantly to your phone and computers.

Built on the [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) plugin and its CLI, using CouchDB as the sync backbone.

---

## How it works

```
┌──────────────────────┐     ┌──────────────┐     ┌────────────────────────────┐
│  Phone / Computer    │     │   CouchDB    │     │  Host (this repo)          │
│  Obsidian + plugin   │◄───►│   server     │◄───►│  livesync-watch.js         │
└──────────────────────┘     └──────────────┘     │  livesync-file-watcher.js  │
                                                   │  ┌──────────────────────┐  │
                                                   │  │ vault/               │  │
                                                   │  │   note.md      ◄─────┼──┼─► AI agent reads
                                                   │  │   .livesync/   ──────┼──┼─► AI agent writes
                                                   │  └──────────────────────┘  │
                                                   └────────────────────────────┘
```

**Inbound** (remote → host): `livesync-watch.js` long-polls the CouchDB `_changes` feed. When your phone saves a note, the watcher detects the change within seconds and runs `livesync-pull.sh`, which syncs the local PouchDB then materialises files to disk. The agent always reads fresh files — no polling needed.

**Outbound** (host → remote): `livesync-file-watcher.js` watches the vault directory with inotify. When the agent writes a file, the watcher debounces and calls `livesync-push.sh` automatically. The agent just writes files — no extra commands needed.

---

## Prerequisites

- **Node.js** v18 or later
- **Git**
- A running **CouchDB** instance reachable from the host (the same one your Obsidian devices already use)
- The **Self-hosted LiveSync** plugin already configured on at least one Obsidian client so you have a setup URI to import

---

## Installation

```bash
git clone --recurse-submodules https://github.com/your-username/obsidian-agent-sync.git
cd obsidian-agent-sync
chmod +x install.sh scripts/*.sh
./install.sh
```

The installer:
1. Initialises the `obsidian-livesync` submodule
2. Installs its npm dependencies and builds the CLI
3. Prompts for your vault path and writes `.env`
4. Creates default LiveSync settings in the vault

If you already have a setup URI from the Obsidian plugin you can pass it directly:

```bash
./install.sh --vault /path/to/vault --uri "obsidian://setuplivesync?settings=..."
```

---

## Configuration

### Apply your setup URI

The setup URI encodes all your CouchDB connection details and encryption settings. Export it from any configured Obsidian client:

> Settings → Community Plugins → Self-hosted LiveSync → ⚙ (copy setup URI)

Then apply it on the host:

```bash
source .env
node obsidian-livesync/src/apps/cli/dist/index.cjs \
  "$LIVESYNC_VAULT_PATH" \
  setup "obsidian://setuplivesync?settings=..."
```

You will be prompted for the passphrase you chose when you first configured the plugin.

### Manual settings

If you prefer, edit `$LIVESYNC_VAULT_PATH/.livesync/settings.json` directly:

```json
{
  "couchDB_URI": "http://localhost:5984",
  "couchDB_USER": "admin",
  "couchDB_PASSWORD": "password",
  "couchDB_DBNAME": "obsidian-livesync",
  "encrypt": true,
  "passphrase": "your-encryption-passphrase",
  "isConfigured": true
}
```

---

## Usage

### Initial pull

Populate the vault from CouchDB for the first time:

```bash
source .env
./scripts/livesync-pull.sh
```

### Start the background watchers

Two watchers run as systemd services (installed automatically by `install.sh` on Linux):

| Service | Direction | What it does |
|---------|-----------|--------------|
| `livesync-watch.service` | inbound | Polls CouchDB `_changes` → runs pull on remote changes |
| `livesync-file-watcher.service` | outbound | Watches vault files → pushes edits to CouchDB |

```bash
# Check status
systemctl status livesync-watch livesync-file-watcher

# Tail logs
journalctl -fu livesync-watch
journalctl -fu livesync-file-watcher
```

To run manually (outside systemd):

```bash
source .env
node scripts/livesync-watch.js &
node scripts/livesync-file-watcher.js &
```

### Push after writing (manual)

The file watcher handles this automatically. If you need to push manually (e.g. after a bulk operation from outside the vault):

```bash
# Push specific files
source .env
./scripts/livesync-push.sh notes/my-note.md projects/plan.md

# Push all changed files (mtime diff)
./scripts/livesync-push.sh
```

### Delete a note

Plain filesystem deletion is **not enough** — the next pull would restore the file from CouchDB. Always use:

```bash
source .env
./scripts/livesync-push.sh --delete notes/old-note.md
```

This marks the note deleted in the local PouchDB and syncs the deletion to CouchDB.

### Manual operations (advanced)

The underlying CLI supports many more operations. After sourcing `.env`:

```bash
CLI="node obsidian-livesync/src/apps/cli/dist/index.cjs"

# List all notes in local DB
$CLI "$LIVESYNC_VAULT_PATH" ls

# Inspect a note (revisions, conflicts, chunks)
$CLI "$LIVESYNC_VAULT_PATH" info notes/my-note.md

# Read a note directly from the DB
$CLI "$LIVESYNC_VAULT_PATH" cat notes/my-note.md

# Resolve a conflict
$CLI "$LIVESYNC_VAULT_PATH" info notes/my-note.md          # find conflicting rev
$CLI "$LIVESYNC_VAULT_PATH" resolve notes/my-note.md 3-abc  # keep the rev you want
```

---

## Agent integration

The agent reads and writes vault files directly — **no sync commands needed**. Two background services handle everything automatically:

- **Inbound**: `livesync-watch.service` keeps vault files fresh when your phone or computer saves a note.
- **Outbound**: `livesync-file-watcher.service` detects any file the agent writes and pushes it to CouchDB within ~2 seconds.

Add this to your agent's system prompt or `CLAUDE.md`:

```
## Obsidian vault

Your Obsidian vault is at: /path/to/vault

- Read notes by reading .md files directly from the vault directory.
- Write notes by writing .md files directly to the vault directory.
- Delete notes by deleting the file — the sync daemon handles propagation.
- The vault is kept in sync with CouchDB automatically. No sync commands needed.
- Do NOT write to .livesync/ — that directory is internal to the sync engine.
```

### Manual push (advanced / edge cases)

The file watcher covers normal edits. For edge cases (bulk renames, moves from outside the vault, deletions):

```bash
source /path/to/obsidian-agent-sync/.env

# Push a specific file
./scripts/livesync-push.sh notes/my-note.md

# Push all files changed since last sync (mtime comparison)
./scripts/livesync-push.sh

# Mark a file deleted in CouchDB (after rm)
./scripts/livesync-push.sh --delete notes/old-note.md
```

---

## Running as a service

### systemd (Linux)

`install.sh` does this automatically. To do it manually:

```bash
INSTALL_DIR=/path/to/obsidian-agent-sync

for svc in livesync-watch livesync-file-watcher; do
    sed "s|INSTALL_DIR|$INSTALL_DIR|g" "$INSTALL_DIR/systemd/${svc}.service" \
        | sudo tee /etc/systemd/system/${svc}.service > /dev/null
done

sudo systemctl daemon-reload
sudo systemctl enable --now livesync-watch livesync-file-watcher

# Tail logs
sudo journalctl -fu livesync-watch
sudo journalctl -fu livesync-file-watcher
```

### launchd (macOS)

Create `~/Library/LaunchAgents/com.obsidian-agent-sync.watch.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.obsidian-agent-sync.watch</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/node</string>
    <string>/path/to/obsidian-agent-sync/scripts/livesync-watch.js</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>LIVESYNC_VAULT_PATH</key>
    <string>/path/to/your/obsidian-vault</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardErrorPath</key>
  <string>/tmp/livesync-watch.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.obsidian-agent-sync.watch.plist
tail -f /tmp/livesync-watch.log
```

---

## Troubleshooting

Run the sanitizer first — it checks and auto-fixes the most common issues:

```bash
source .env && ./scripts/sanitize-settings.sh
```

---

**`LIVESYNC_VAULT_PATH not set`**
Run `source .env` before calling scripts, or export the variable in your shell profile.

---

**`IO error: .../LOCK` on startup**
LevelDB (the local database engine) leaves a `LOCK` file when a CLI process crashes. The lockfile is at `$VAULT/.livesync/<db-name>/LOCK`.

`livesync-pull.sh` removes stale locks automatically before each run. To clean them manually:

```bash
source .env
find "$LIVESYNC_VAULT_PATH/.livesync" -name "LOCK" -delete
```

---

**`Pull already running`**
A previous pull is still in progress. The process-level lockfile is at `/tmp/livesync-pull-<hash>.lock`. If you are sure no pull is running, delete it manually.

---

**Settings copied from Android / mobile device**
Do not copy `settings.json` directly from your phone. Use the setup URI instead — it is portable and strips device-specific paths:

> Obsidian → Settings → Self-hosted LiveSync → ⚙ → Copy setup URI

Then apply it:
```bash
source .env
node obsidian-livesync/src/apps/cli/dist/index.cjs \
  "$LIVESYNC_VAULT_PATH" setup "obsidian://setuplivesync?settings=..."
```

The sanitizer detects Android paths in settings and will warn you if this happened.

---

**`The remote database is locked and this device is not yet accepted`**
The host needs to be accepted by the plugin. Open Obsidian on one of your other devices, go to the LiveSync settings, and accept the new device. Then retry.

---

**`HTTP 401` from CouchDB**
Your credentials in `.livesync/settings.json` are wrong. Re-apply the setup URI or fix them manually.

---

**Watcher connects but pull never fires**
Verify `isConfigured: true` is set in `.livesync/settings.json`. Check CouchDB is reachable with:
```bash
curl -s -u user:pass http://your-couchdb:5984/your-db/_changes?since=now
```

---

**Conflicts (`*` in `ls` output)**
```bash
source .env
CLI="node obsidian-livesync/src/apps/cli/dist/index.cjs"
$CLI "$LIVESYNC_VAULT_PATH" info notes/conflicted.md
$CLI "$LIVESYNC_VAULT_PATH" resolve notes/conflicted.md <rev-to-keep>
```

---

## Repository structure

```
obsidian-agent-sync/
├── scripts/
│   ├── livesync-pull.sh           inbound sync (CouchDB → PouchDB → files)
│   ├── livesync-push.sh           outbound sync (files → PouchDB → CouchDB)
│   ├── livesync-watch.js          CouchDB _changes daemon (triggers pull)
│   ├── livesync-file-watcher.js   vault inotify daemon (triggers push)
│   └── sanitize-settings.sh       validate/fix settings.json
├── systemd/
│   ├── livesync-watch.service         systemd unit for livesync-watch.js
│   └── livesync-file-watcher.service  systemd unit for livesync-file-watcher.js
├── patches/
│   └── 01-db-path-in-livesync-dir.patch   upstream fixes (applied by install.sh)
├── obsidian-livesync/         upstream plugin repo (git submodule)
│   └── src/apps/cli/dist/     built CLI (generated by install.sh)
├── install.sh                 one-shot setup (init, patch, build, .env, systemd)
├── package.json               outer deps (chokidar for file watcher)
└── README.md
```

### Why patches?

`obsidian-livesync` is tracked as a git submodule pinned to a specific upstream commit. The `patches/` directory contains minimal fixes that are not yet merged upstream. `install.sh` applies them idempotently with `git apply` after `git submodule update --init`.

---

## Upgrading the upstream CLI

```bash
cd obsidian-livesync
git pull origin master
cd src/apps/cli
npm run build
```
