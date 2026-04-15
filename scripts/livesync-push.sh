#!/usr/bin/env bash
# livesync-push.sh — push agent-written changes to CouchDB
# Usage:
#   livesync-push.sh                        mirror all changes (mtime comparison)
#   livesync-push.sh note.md folder/x.md   push specific files (vault-relative paths)
#   livesync-push.sh /abs/path/note.md      push by absolute path (must be inside vault)
#   livesync-push.sh --delete note.md       mark a file deleted in the DB then sync
#
# Env: LIVESYNC_VAULT_PATH  path to vault directory
#
# NOTE: mirror does NOT propagate deletions. For deleted files use --delete.
# Flow: filesystem → local PouchDB (push/mirror) → CouchDB (sync)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="node $SCRIPT_DIR/../obsidian-livesync/src/apps/cli/dist/index.cjs"
VAULT="${LIVESYNC_VAULT_PATH:?Error: LIVESYNC_VAULT_PATH is not set}"

log() { echo "[livesync-push] $(date -Iseconds) $*" >&2; }

# Clear stale LevelDB LOCK files left by a crashed CLI process.
# Each CLI invocation opens LevelDB exclusively; if a previous process did not
# release the OS flock the LOCK file remains and the next run fails with
# "cannot be initialised".  The OS releases the flock on process exit even if
# the file is not deleted, so it is safe to remove any LOCK not held by a
# currently-running process.
clear_stale_leveldb_locks() {
    while IFS= read -r -d '' leveldb_lock; do
        if command -v lsof &>/dev/null && lsof "$leveldb_lock" 2>/dev/null | grep -q .; then
            : # genuinely held — leave it
        else
            log "Removing stale LevelDB lock: $leveldb_lock"
            rm -f "$leveldb_lock"
        fi
    done < <(find "$VAULT/.livesync" -name "LOCK" -print0 2>/dev/null)
}
clear_stale_leveldb_locks

# Convert a path to vault-relative (strips VAULT prefix if absolute)
to_vault_rel() {
    local p="$1"
    if [[ "$p" == /* ]]; then
        # absolute — must be inside vault
        local rel
        rel="${p#$VAULT/}"
        if [[ "$rel" == /* ]] || [[ "$rel" == "$p" ]]; then
            echo "Error: $p is outside vault $VAULT" >&2
            exit 1
        fi
        echo "$rel"
    else
        # already relative — normalise away any leading ./
        echo "${p#./}"
    fi
}

DELETE_MODE=0
FILES=()

for arg in "$@"; do
    case "$arg" in
        --delete|-d) DELETE_MODE=1 ;;
        *)           FILES+=("$arg") ;;
    esac
done

if [ "${#FILES[@]}" -eq 0 ] && [ "$DELETE_MODE" -eq 0 ]; then
    # No files specified — mirror everything (mtime-based diff)
    log "No files specified — mirroring all changes..."
    $CLI "$VAULT" mirror
else
    for file in "${FILES[@]}"; do
        rel="$(to_vault_rel "$file")"
        if [ "$DELETE_MODE" -eq 1 ]; then
            log "Deleting $rel from DB..."
            $CLI "$VAULT" rm "$rel"
        else
            # Resolve to absolute for push <src>
            if [[ "$file" == /* ]]; then
                abs="$file"
            else
                abs="$VAULT/$rel"
            fi
            if [ ! -f "$abs" ]; then
                echo "Error: file not found: $abs" >&2
                exit 1
            fi
            log "Pushing $rel..."
            $CLI "$VAULT" push "$abs" "$rel"
        fi
    done
fi

log "Pushing local PouchDB → CouchDB..."
$CLI "$VAULT" sync-push
log "Done."
