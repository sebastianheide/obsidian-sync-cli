#!/usr/bin/env bash
# sanitize-settings.sh — validate and sanitize LiveSync settings.json for CLI use
#
# Usage:  ./scripts/sanitize-settings.sh
# Env:    LIVESYNC_VAULT_PATH  path to vault directory
#
# Checks for known incompatibilities when settings were imported from a mobile
# device or copied from another platform. Patches what it can; warns about the
# rest.

set -euo pipefail

VAULT="${LIVESYNC_VAULT_PATH:?Error: LIVESYNC_VAULT_PATH is not set}"
SETTINGS="$VAULT/.livesync/settings.json"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${BOLD}[sanitize]${NC} $*"; }
ok()    { echo -e "${GREEN}[sanitize]${NC} $*"; }
warn()  { echo -e "${YELLOW}[sanitize]${NC} $*"; }
err()   { echo -e "${RED}[sanitize]${NC} $*" >&2; }

if [ ! -f "$SETTINGS" ]; then
    err "Settings not found: $SETTINGS"
    err "Run install.sh first to create settings, then apply your setup URI."
    exit 1
fi

info "Checking $SETTINGS ..."

# ── Read with node (avoids jq dependency) ────────────────────────────────────
read_setting() {
    node -pe "
        const s = JSON.parse(require('fs').readFileSync('$SETTINGS','utf8'));
        const v = s['$1'];
        v === undefined ? '' : String(v);
    " 2>/dev/null || echo ""
}

write_setting() {
    local key="$1" val="$2"
    node -e "
        const fs = require('fs');
        const s = JSON.parse(fs.readFileSync('$SETTINGS','utf8'));
        s['$key'] = $val;
        fs.writeFileSync('$SETTINGS', JSON.stringify(s, null, 2), 'utf8');
    "
}

ISSUES=0

# ── 1. isConfigured ───────────────────────────────────────────────────────────
IS_CONFIGURED="$(read_setting isConfigured)"
if [ "$IS_CONFIGURED" != "true" ]; then
    warn "isConfigured is not true — have you applied the setup URI?"
    warn "  Run: node obsidian-livesync/src/apps/cli/dist/index.cjs \\"
    warn "         \"\$LIVESYNC_VAULT_PATH\" setup \"obsidian://setuplivesync?settings=...\""
    ISSUES=$((ISSUES+1))
fi

# ── 2. useIndexedDBAdapter ────────────────────────────────────────────────────
INDEXED_DB="$(read_setting useIndexedDBAdapter)"
if [ "$INDEXED_DB" = "true" ]; then
    warn "useIndexedDBAdapter=true — incompatible with Node.js (browser-only). Patching to false..."
    write_setting useIndexedDBAdapter false
    ok "  Patched: useIndexedDBAdapter → false"
fi

# ── 3. Android / mobile paths ─────────────────────────────────────────────────
COUCH_URI="$(read_setting couchDB_URI)"
MOBILE_PATH_PATTERNS=(
    "/storage/emulated"
    "/data/user"
    "/sdcard"
    "file:///android"
    "content://"
)
for pattern in "${MOBILE_PATH_PATTERNS[@]}"; do
    if echo "$COUCH_URI" | grep -qi "$pattern"; then
        err "couchDB_URI looks like a mobile path: $COUCH_URI"
        err "This settings.json was likely copied directly from a mobile device."
        err "Use the setup URI instead — export it from Obsidian:"
        err "  Settings → Self-hosted LiveSync → Copy Setup URI"
        ISSUES=$((ISSUES+1))
        break
    fi
done

# ── 4. CouchDB URI reachability ───────────────────────────────────────────────
if [ -n "$COUCH_URI" ] && [ "$IS_CONFIGURED" = "true" ]; then
    COUCH_USER="$(read_setting couchDB_USER)"
    COUCH_PASS="$(read_setting couchDB_PASSWORD)"
    COUCH_DB="$(read_setting couchDB_DBNAME)"

    if [ -n "$COUCH_USER" ]; then
        HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
            --user "$COUCH_USER:$COUCH_PASS" \
            "$COUCH_URI/$COUCH_DB" 2>/dev/null || echo "000")
    else
        HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
            "$COUCH_URI/$COUCH_DB" 2>/dev/null || echo "000")
    fi

    case "$HTTP_CODE" in
        200|201) ok "CouchDB reachable ($COUCH_URI/$COUCH_DB) — HTTP $HTTP_CODE" ;;
        000)     warn "CouchDB unreachable at $COUCH_URI — check network / VPN / firewall" ; ISSUES=$((ISSUES+1)) ;;
        401)     err  "CouchDB auth failed (HTTP 401) — wrong credentials in settings.json" ; ISSUES=$((ISSUES+1)) ;;
        404)     warn "CouchDB database not found (HTTP 404): $COUCH_DB — it will be created on first sync" ;;
        *)       warn "CouchDB returned HTTP $HTTP_CODE for $COUCH_URI/$COUCH_DB" ; ISSUES=$((ISSUES+1)) ;;
    esac
fi

# ── 5. Stale LevelDB LOCK files ───────────────────────────────────────────────
LIVESYNC_DIR="$VAULT/.livesync"
STALE_LOCKS=()
while IFS= read -r -d '' lockfile; do
    if command -v lsof &>/dev/null; then
        if lsof "$lockfile" 2>/dev/null | grep -q .; then
            warn "LOCK held by running process: $lockfile (leave it)"
        else
            STALE_LOCKS+=("$lockfile")
        fi
    else
        STALE_LOCKS+=("$lockfile")
    fi
done < <(find "$LIVESYNC_DIR" -name "LOCK" -print0 2>/dev/null)

if [ ${#STALE_LOCKS[@]} -gt 0 ]; then
    warn "Found ${#STALE_LOCKS[@]} stale LOCK file(s) — removing..."
    for lockfile in "${STALE_LOCKS[@]}"; do
        rm -f "$lockfile"
        ok "  Removed: $lockfile"
    done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ "$ISSUES" -eq 0 ]; then
    ok "Settings look good."
else
    err "$ISSUES issue(s) found. See warnings above."
    exit 1
fi
