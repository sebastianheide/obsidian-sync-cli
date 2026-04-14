# obsidian-agent-sync

Headless Obsidian vault sync for AI agents and servers. Lets a machine without a display read and write your Obsidian notes and have every change flow instantly to your phone and computers.

Built on the [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) plugin and its CLI, using CouchDB as the sync backbone.

---

## How it works

```
┌──────────────────────┐     ┌──────────────┐     ┌──────────────────────┐
│  Phone / Computer    │     │   CouchDB    │     │  Host (this repo)    │
│  Obsidian + plugin   │◄───►│   server     │◄───►│  livesync-watch.js   │
└──────────────────────┘     └──────────────┘     │  ┌────────────────┐  │
                                                   │  │ vault/         │  │
                                                   │  │   note.md      │◄─┼─► AI agent
                                                   │  │   .livesync/   │  │
                                                   │  └────────────────┘  │
                                                   └──────────────────────┘
```

**Inbound** (remote → host): `livesync-watch.js` long-polls the CouchDB `_changes` feed. When your phone saves a note, the watcher detects the change within seconds and runs `livesync-pull.sh`, which syncs the local PouchDB then materialises files to disk. The agent always reads fresh files — no polling needed.

**Outbound** (host → remote): The agent writes files to disk normally, then calls `scripts/livesync-push.sh`. The script stores the changes in the local PouchDB and pushes them to CouchDB. All devices pick up the change within seconds.

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

### Start the background watcher

Keeps the vault up-to-date as your other devices save notes:

```bash
source .env
node scripts/livesync-watch.js
```

The watcher runs until killed. Logs go to stderr. Stop with `Ctrl-C` or `SIGTERM`.

Run it as a persistent service — see [Running as a service](#running-as-a-service) below.

### Push after writing

After the agent (or any script) writes or renames a file:

```bash
# Push specific files (fastest)
source .env
./scripts/livesync-push.sh notes/my-note.md projects/plan.md

# Or push all changed files (mtime diff — useful after bulk operations)
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

The agent reads files directly from the filesystem — no special command needed. The watcher keeps them fresh.

The only thing the agent must do after writing is call `livesync-push.sh`. Add this to your agent's system prompt or `CLAUDE.md`:

```
## Obsidian vault sync

Your Obsidian vault is at: $LIVESYNC_VAULT_PATH
The sync tooling lives at: /path/to/obsidian-agent-sync

Rules:
- Read notes by reading files directly from the vault directory.
- After writing or renaming any note, run:
    source /path/to/obsidian-agent-sync/.env
    /path/to/obsidian-agent-sync/scripts/livesync-push.sh <vault-relative-path>
  Example: livesync-push.sh notes/meeting-2024-01-15.md
- To delete a note, delete the file first, then run:
    livesync-push.sh --delete <vault-relative-path>
- To push all pending changes at once:
    livesync-push.sh   (no arguments)
- The background watcher (livesync-watch.js) keeps the vault up-to-date
  automatically. You do not need to pull manually.
```

---

## Running as a service

### systemd (Linux)

Create `/etc/systemd/system/livesync-watch.service`:

```ini
[Unit]
Description=Obsidian LiveSync watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=YOUR_USER
WorkingDirectory=/path/to/obsidian-agent-sync
EnvironmentFile=/path/to/obsidian-agent-sync/.env
ExecStart=/usr/bin/node /path/to/obsidian-agent-sync/scripts/livesync-watch.js
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now livesync-watch
sudo journalctl -u livesync-watch -f   # tail logs
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

**`LIVESYNC_VAULT_PATH not set`**
Run `source .env` before calling scripts, or export the variable in your shell profile.

**`Pull already running`**
A previous pull is still in progress. The lockfile is at `/tmp/livesync-pull-<hash>.lock`. If you are sure no pull is running, delete it manually.

**`The remote database is locked and this device is not yet accepted`**
The host needs to be accepted by the plugin. Open Obsidian on one of your other devices, go to the LiveSync settings, and accept the new device. Then retry.

**`HTTP 401` from CouchDB**
Your credentials in `.livesync/settings.json` are wrong. Re-apply the setup URI or fix them manually.

**Watcher connects but pull never fires**
Verify `isConfigured: true` is set in `.livesync/settings.json`. Check CouchDB is reachable with:
```bash
curl -s -u user:pass http://your-couchdb:5984/your-db/_changes?since=now
```

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
│   ├── livesync-pull.sh       inbound sync (CouchDB → files)
│   ├── livesync-push.sh       outbound sync (files → CouchDB)
│   └── livesync-watch.js      background watcher daemon
├── obsidian-livesync/         upstream plugin repo (git submodule)
│   └── src/apps/cli/dist/     built CLI (generated by install.sh)
├── install.sh                 one-shot setup script
├── .env.example               environment variable template
└── README.md
```

---

## Upgrading the upstream CLI

```bash
cd obsidian-livesync
git pull origin master
cd src/apps/cli
npm run build
```
