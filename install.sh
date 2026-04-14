#!/usr/bin/env bash
# install.sh — one-shot setup for obsidian-agent-sync
#
# Usage:
#   ./install.sh                          interactive setup
#   ./install.sh --vault /path/to/vault   non-interactive (skips prompts)
#   ./install.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
CLI_DIR="$SCRIPT_DIR/obsidian-livesync/src/apps/cli"
CLI_DIST="$CLI_DIR/dist/index.cjs"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BOLD}[setup]${NC} $*"; }
success() { echo -e "${GREEN}[setup]${NC} $*"; }
warn()    { echo -e "${YELLOW}[setup]${NC} $*"; }
err()     { echo -e "${RED}[setup]${NC} $*" >&2; }

# ── Args ──────────────────────────────────────────────────────────────────────
VAULT_ARG=""
SETUP_URI=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault)  VAULT_ARG="$2"; shift 2 ;;
        --uri)    SETUP_URI="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ./install.sh [--vault /path/to/vault] [--uri obsidian://setuplivesync?settings=...]"
            exit 0 ;;
        *) err "Unknown argument: $1"; exit 1 ;;
    esac
done

echo ""
echo -e "${BOLD}obsidian-agent-sync installer${NC}"
echo "────────────────────────────────────"
echo ""

# ── 1. Node.js check ──────────────────────────────────────────────────────────
info "Checking Node.js..."
if ! command -v node &>/dev/null; then
    err "Node.js is required but not found. Install from https://nodejs.org (v18+)."
    exit 1
fi
NODE_VERSION=$(node --version)
info "  Node.js $NODE_VERSION"

# ── 2. Git submodule ──────────────────────────────────────────────────────────
info "Initialising obsidian-livesync submodule..."
git -C "$SCRIPT_DIR" submodule update --init --recursive
success "Submodule ready."

# ── 3. Apply patches ──────────────────────────────────────────────────────────
PATCHES_DIR="$SCRIPT_DIR/patches"
if [ -d "$PATCHES_DIR" ] && compgen -G "$PATCHES_DIR/*.patch" > /dev/null 2>&1; then
    info "Applying patches to obsidian-livesync..."
    for patch_file in "$PATCHES_DIR"/*.patch; do
        patch_name="$(basename "$patch_file")"
        if git -C "$SCRIPT_DIR/obsidian-livesync" apply --check "$patch_file" 2>/dev/null; then
            git -C "$SCRIPT_DIR/obsidian-livesync" apply "$patch_file"
            success "  Applied: $patch_name"
        elif git -C "$SCRIPT_DIR/obsidian-livesync" apply --reverse --check "$patch_file" 2>/dev/null; then
            info "  Already applied: $patch_name"
        else
            warn "  Could not apply $patch_name cleanly — upstream may have changed. Check patches/ for conflicts."
        fi
    done
fi

# ── 4. Build CLI ──────────────────────────────────────────────────────────────
if [ -f "$CLI_DIST" ]; then
    info "CLI already built at $CLI_DIST"
else
    info "Installing obsidian-livesync dependencies..."
    npm install --prefix "$SCRIPT_DIR/obsidian-livesync" --silent

    info "Building CLI..."
    (cd "$CLI_DIR" && npm run build --silent)
    success "CLI built."
fi

# ── 4. Vault path ─────────────────────────────────────────────────────────────
if [ -n "$VAULT_ARG" ]; then
    VAULT_PATH="$VAULT_ARG"
else
    echo ""
    echo "Enter the absolute path to your Obsidian vault directory."
    echo "This is the folder that contains your .md notes."
    read -r -p "Vault path: " VAULT_PATH
fi

VAULT_PATH="$(realpath "$VAULT_PATH" 2>/dev/null || echo "$VAULT_PATH")"

if [ ! -d "$VAULT_PATH" ]; then
    warn "Directory does not exist: $VAULT_PATH"
    read -r -p "Create it? [y/N] " yn
    case "$yn" in
        [Yy]*) mkdir -p "$VAULT_PATH" ;;
        *)     err "Vault directory required."; exit 1 ;;
    esac
fi

# ── 6. Write .env ─────────────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
    warn ".env already exists — not overwriting."
else
    cat > "$ENV_FILE" <<EOF
LIVESYNC_VAULT_PATH=$VAULT_PATH
LIVESYNC_PULL_DEBOUNCE_MS=3000
EOF
    success "Created .env"
fi

# ── 7. Init vault settings ────────────────────────────────────────────────────
LIVESYNC_SETTINGS="$VAULT_PATH/.livesync/settings.json"

if [ -f "$LIVESYNC_SETTINGS" ]; then
    info "Vault already has LiveSync settings — skipping init."
else
    info "Creating default LiveSync settings..."
    node "$CLI_DIST" init-settings "$LIVESYNC_SETTINGS"

    # Apply setup URI if provided
    if [ -n "$SETUP_URI" ]; then
        info "Applying setup URI..."
        node "$CLI_DIST" "$VAULT_PATH" --settings "$LIVESYNC_SETTINGS" setup "$SETUP_URI"
        success "Setup URI applied."
    else
        echo ""
        echo -e "${YELLOW}Action required:${NC} Apply your Obsidian LiveSync setup URI."
        echo ""
        echo "In Obsidian (on any already-configured device):"
        echo "  Settings → Community Plugins → Self-hosted LiveSync → ⚙ → Copy setup URI"
        echo ""
        echo "Then run:"
        echo "  source .env && node obsidian-livesync/src/apps/cli/dist/index.cjs \\"
        echo "    \"\$LIVESYNC_VAULT_PATH\" setup \"obsidian://setuplivesync?settings=...\""
        echo ""
        echo -e "${RED}Important:${NC} Do NOT copy settings.json from your phone/tablet."
        echo "  Use the setup URI — it strips device-specific paths and is portable."
        echo ""
    fi
fi

# ── 8. Sanitize settings ──────────────────────────────────────────────────────
LIVESYNC_SETTINGS="$VAULT_PATH/.livesync/settings.json"
if [ -f "$LIVESYNC_SETTINGS" ]; then
    info "Validating settings..."
    LIVESYNC_VAULT_PATH="$VAULT_PATH" bash "$SCRIPT_DIR/scripts/sanitize-settings.sh" || true
fi

# ── 8. Done ───────────────────────────────────────────────────────────────────
echo ""
success "Installation complete!"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo ""
echo "  1. Apply your setup URI (if not done above)"
echo "  2. Run an initial pull to populate the vault:"
echo "       source .env && ./scripts/livesync-pull.sh"
echo "  3. Start the background watcher (keeps vault up-to-date):"
echo "       source .env && node scripts/livesync-watch.js"
echo "  4. Tell your agent to call livesync-push.sh after writing files."
echo "     See README.md → Agent Integration for the system-prompt snippet."
echo ""
