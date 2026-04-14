#!/usr/bin/env bash
# livesync-pull.sh — pull latest changes from CouchDB and materialize to filesystem
# Usage: livesync-pull.sh
# Env:   LIVESYNC_VAULT_PATH  path to vault directory (also acts as local DB root)
#
# Flow: CouchDB → local PouchDB (sync) → filesystem files (mirror)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="node $SCRIPT_DIR/../obsidian-livesync/src/apps/cli/dist/index.cjs"
VAULT="${LIVESYNC_VAULT_PATH:?Error: LIVESYNC_VAULT_PATH is not set}"
LOCK_FILE="/tmp/livesync-pull-$(echo "$VAULT" | md5).lock"

log() { echo "[livesync-pull] $(date -Iseconds) $*" >&2; }

# Prevent concurrent pulls
if [ -f "$LOCK_FILE" ]; then
    PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        log "Pull already running (pid $PID), skipping."
        exit 0
    fi
    log "Stale lock found, removing."
    rm -f "$LOCK_FILE"
fi

echo "$$" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# Clear any stale LevelDB LOCK files left by a previously crashed CLI process.
# These live in $VAULT/.livesync/ and cause "IO error: .../LOCK" on next run.
while IFS= read -r -d '' leveldb_lock; do
    if command -v lsof &>/dev/null && lsof "$leveldb_lock" 2>/dev/null | grep -q .; then
        : # genuinely held by a running process — leave it
    else
        log "Removing stale LevelDB lock: $leveldb_lock"
        rm -f "$leveldb_lock"
    fi
done < <(find "$VAULT/.livesync" -name "LOCK" -print0 2>/dev/null)

log "Syncing from CouchDB → local PouchDB..."
$CLI "$VAULT" sync

log "Materializing local PouchDB → filesystem..."
$CLI "$VAULT" mirror

log "Done."
