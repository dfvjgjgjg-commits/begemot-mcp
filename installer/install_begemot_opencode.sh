#!/usr/bin/env bash
# ============================================================
#  BEGEMOT MCP - OpenCode Auto-Installer (macOS / Linux)
#  Local install, no Docker: fetches the repo, deploys the MCP server,
#  configures OpenCode and starts the local Streamable HTTP endpoint.
#
#  One-liner:
#    curl -fsSL https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/install_begemot_opencode.sh | bash
# ============================================================
set -euo pipefail

REPO_OWNER="dfvjgjgjg-commits"
REPO_NAME="begemot-mcp"
BRANCH="main"
REPO_URL="https://github.com/$REPO_OWNER/$REPO_NAME"
API_KEY="9db6f52871e4c30a"
HTTP_PORT="${BEGEMOT_HTTP_PORT:-8788}"
NODE_VERSION="v22.12.0"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
MCP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/begemot-mcp"
PROMPT_FILE="$CONFIG_DIR/begemot_prompt.md"
PLUGIN_DIR="$CONFIG_DIR/plugins/greenlight"

GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; CYAN='\033[36m'; DIM='\033[90m'; NC='\033[0m'

ok()   { printf "${GREEN}  OK: %s${NC}\n" "$1"; }
warn() { printf "${YELLOW}  WARN: %s${NC}\n" "$1"; }
err()  { printf "${RED}  ERROR: %s${NC}\n" "$1" >&2; }
die()  { printf "${RED}  ERROR: %s${NC}\n" "$1" >&2; exit 1; }
step() { printf "\n${YELLOW}%s${NC}\n" "$1"; }

printf "\n${GREEN}  ============================================${NC}\n"
printf "${GREEN}  BEGEMOT MCP - OpenCode Auto-Installer${NC}\n"
printf "${DIM}  local install, no Docker${NC}\n"
printf "${GREEN}  ============================================${NC}\n"

TMP_BEGEMOT="$(mktemp -d 2>/dev/null || mktemp -d -t begemot)"
trap 'rm -rf "$TMP_BEGEMOT"' EXIT

# ------------------------------------------------------------
# [1/7] Node.js
# ------------------------------------------------------------
step "[1/8] Node.js..."
if ! command -v node >/dev/null 2>&1; then
    warn "Node.js not found"
    if command -v brew >/dev/null 2>&1; then
        printf "${DIM}  installing via Homebrew (may take a while)...${NC}\n"
        brew install node >/dev/null 2>&1 || die "brew install node failed"
    else
        case "$(uname -m)" in
            arm64|aarch64) NODE_ARCH="arm64" ;;
            x86_64|amd64)  NODE_ARCH="x64" ;;
            *) die "unsupported CPU architecture: $(uname -m)" ;;
        esac
        NODE_URL="https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-darwin-${NODE_ARCH}.tar.gz"
        printf "${DIM}  downloading %s${NC}\n" "$NODE_URL"
        curl -fsSL "$NODE_URL" -o "$TMP_BEGEMOT/node.tar.gz" || die "cannot download Node.js"
        mkdir -p "$HOME/.local"
        rm -rf "$HOME/.local/node"
        tar -xzf "$TMP_BEGEMOT/node.tar.gz" -C "$HOME/.local" || die "cannot extract Node.js"
        mv "$HOME/.local/node-${NODE_VERSION}-darwin-${NODE_ARCH}" "$HOME/.local/node"
        export PATH="$HOME/.local/node/bin:$PATH"
    fi
fi

NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || die "node not found after install"
NPM_BIN="$(command -v npm || true)"
if [ -z "$NPM_BIN" ] && [ -x "$HOME/.local/node/bin/npm" ]; then
    NPM_BIN="$HOME/.local/node/bin/npm"
fi
[ -n "$NPM_BIN" ] || die "npm not found. Install Node.js: https://nodejs.org/"
ok "Node.js $("$NODE_BIN" -v 2>/dev/null)"
printf "${DIM}  node: %s${NC}\n" "$NODE_BIN"
case "$NODE_BIN" in
    */.nvm/*) warn "nvm detected: node path is version-specific; re-run this installer after switching Node versions" ;;
esac

# ------------------------------------------------------------
# [2/7] Fetch the current source from GitHub (no embedded payload)
# ------------------------------------------------------------
step "[2/8] Fetching $REPO_OWNER/$REPO_NAME @ $BRANCH..."
SRC_DIR=""

fetch_ok() {
    [ -n "$1" ] && [ -f "$1/mcp/core.mjs" ] && [ -f "$1/mcp/server.js" ] \
        && [ -f "$1/plugin/greenlight/index.js" ] && [ -f "$1/prompt/begemot_prompt.md" ]
}

if command -v git >/dev/null 2>&1; then
    if git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$TMP_BEGEMOT/repo" >/dev/null 2>&1 \
       && fetch_ok "$TMP_BEGEMOT/repo"; then
        SRC_DIR="$TMP_BEGEMOT/repo"
        ok "cloned via git"
    fi
fi

if [ -z "$SRC_DIR" ]; then
    if curl -fsSL "$REPO_URL/archive/refs/heads/$BRANCH.tar.gz" -o "$TMP_BEGEMOT/src.tar.gz" 2>/dev/null \
       && tar -xzf "$TMP_BEGEMOT/src.tar.gz" -C "$TMP_BEGEMOT" 2>/dev/null; then
        for d in "$TMP_BEGEMOT"/*/; do
            if fetch_ok "${d%/}"; then SRC_DIR="${d%/}"; break; fi
        done
        [ -n "$SRC_DIR" ] && ok "downloaded archive"
    fi
fi

if [ -z "$SRC_DIR" ]; then
    if command -v curl >/dev/null 2>&1; then
        for f in core.mjs server.js server-http.mjs config.json package.json package-lock.json; do
            curl -fsSL "$REPO_URL/raw/$BRANCH/mcp/$f" -o "$TMP_BEGEMOT/$f" 2>/dev/null || true
        done
        mkdir -p "$TMP_BEGEMOT/drop/plugins/greenlight"
        cp "$TMP_BEGEMOT"/core.mjs "$TMP_BEGEMOT"/server.js "$TMP_BEGEMOT"/server-http.mjs \
           "$TMP_BEGEMOT"/config.json "$TMP_BEGEMOT"/package.json "$TMP_BEGEMOT"/package-lock.json \
           "$TMP_BEGEMOT/drop/" 2>/dev/null || true
        curl -fsSL "$REPO_URL/raw/$BRANCH/plugin/greenlight/index.js" -o "$TMP_BEGEMOT/drop/plugins/greenlight/index.js" 2>/dev/null || true
        curl -fsSL "$REPO_URL/raw/$BRANCH/plugin/greenlight/package.json" -o "$TMP_BEGEMOT/drop/plugins/greenlight/package.json" 2>/dev/null || true
        curl -fsSL "$REPO_URL/raw/$BRANCH/prompt/begemot_prompt.md" -o "$TMP_BEGEMOT/drop/begemot_prompt.md" 2>/dev/null || true
        if fetch_ok "$TMP_BEGEMOT/drop" || { [ -f "$TMP_BEGEMOT/drop/core.mjs" ] && [ -f "$TMP_BEGEMOT/drop/server.js" ]; }; then
            SRC_DIR="$TMP_BEGEMOT/drop"
            ok "downloaded file-by-file"
        fi
    fi
fi

[ -n "$SRC_DIR" ] || die "cannot fetch $REPO_URL - github.com must be reachable"

# ------------------------------------------------------------
# [3/7] Deploy files
# ------------------------------------------------------------
step "[3/8] Deploying to $MCP_DIR..."
mkdir -p "$MCP_DIR/plugins/greenlight" "$CONFIG_DIR" "$PLUGIN_DIR"

if [ -d "$SRC_DIR/mcp" ]; then
    ( cd "$SRC_DIR" && tar -cf - --exclude='node_modules' mcp/. ) | ( cd "$MCP_DIR" && tar -xf - --strip-components=1 )
else
    cp "$SRC_DIR"/*.mjs "$SRC_DIR"/*.js "$SRC_DIR"/*.json "$MCP_DIR/" 2>/dev/null || true
fi

if [ -d "$SRC_DIR/plugin/greenlight" ]; then
    cp "$SRC_DIR/plugin/greenlight/"* "$MCP_DIR/plugins/greenlight/" 2>/dev/null || true
fi

if [ -f "$SRC_DIR/prompt/begemot_prompt.md" ]; then
    cp "$SRC_DIR/prompt/begemot_prompt.md" "$MCP_DIR/begemot_prompt.md"
elif [ -f "$SRC_DIR/begemot_prompt.md" ]; then
    cp "$SRC_DIR/begemot_prompt.md" "$MCP_DIR/begemot_prompt.md"
fi

[ -f "$MCP_DIR/core.mjs" ] || die "deploy incomplete: core.mjs missing in $MCP_DIR"
[ -f "$MCP_DIR/server.js" ] || die "deploy incomplete: server.js missing in $MCP_DIR"
[ -f "$MCP_DIR/server-http.mjs" ] || warn "server-http.mjs missing - local HTTP endpoint will not start"
ok "files deployed (core.mjs, server.js, config.json, plugin, prompt)"

# the merge module, the removal module and the doctor travel with the install:
# both installers share the exact same logic, the doctor is what proves the
# install works, and the removal module is what lets the uninstaller clean the
# config without fetching anything
mkdir -p "$MCP_DIR/installer"
for f in merge-opencode-config.mjs unmerge-opencode-config.mjs doctor.mjs; do
    if [ -f "$SRC_DIR/installer/$f" ]; then
        cp "$SRC_DIR/installer/$f" "$MCP_DIR/installer/$f"
    elif ! [ -f "$MCP_DIR/installer/$f" ]; then
        curl -fsSL "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$BRANCH/installer/$f" \
            -o "$MCP_DIR/installer/$f" 2>/dev/null || true
    fi
done
[ -f "$MCP_DIR/installer/merge-opencode-config.mjs" ] || die "merge module missing"
[ -f "$MCP_DIR/installer/doctor.mjs" ] || die "doctor missing"

cp "$MCP_DIR/begemot_prompt.md" "$PROMPT_FILE"
cp "$MCP_DIR/plugins/greenlight/index.js" "$PLUGIN_DIR/index.js"
if [ -f "$MCP_DIR/plugins/greenlight/package.json" ]; then
    cp "$MCP_DIR/plugins/greenlight/package.json" "$PLUGIN_DIR/package.json"
fi
ok "prompt -> $PROMPT_FILE"
ok "plugin -> $PLUGIN_DIR"

# ------------------------------------------------------------
# [4/7] npm install
# ------------------------------------------------------------
step "[4/8] npm install..."
( cd "$MCP_DIR" && "$NPM_BIN" install --no-audit --no-fund ) || die "npm install failed"
ok "dependencies installed"

# ------------------------------------------------------------
# [5/8] Configure OpenCode (surgical JSONC merge + backup)
# ------------------------------------------------------------
step "[5/8] Configuring OpenCode..."
mkdir -p "$CONFIG_DIR"

# back up every config file we are about to touch
for CF in "$CONFIG_DIR/opencode.jsonc" "$CONFIG_DIR/opencode.json"; do
    if [ -f "$CF" ]; then
        BACKUP="$CF.bak.$(date +%Y%m%d%H%M%S)"
        cp "$CF" "$BACKUP"
        printf "${DIM}  backup: %s${NC}\n" "$BACKUP"
    fi
done

# The module writes into EVERY config file that exists (OpenCode unions
# opencode.json and opencode.jsonc, so a single file could leave the entry
# shadowed by the other one's mcp block) and keeps each file's own shape:
# flat mcp.<name> stays flat, mcp.servers stays nested. The file is edited as
# text, so the user's comments and formatting survive.
"$NODE_BIN" "$MCP_DIR/installer/merge-opencode-config.mjs" \
    "$CONFIG_DIR" "$PROMPT_FILE" "$MCP_DIR" "$NODE_BIN" "$PLUGIN_DIR" "auto" \
    || die "config merge failed"
ok "OpenCode config updated"

# ------------------------------------------------------------
# [6/7] Local Streamable HTTP endpoint (autostart, no Docker)
# ------------------------------------------------------------
step "[6/8] Local HTTP endpoint on 127.0.0.1:$HTTP_PORT (no Docker)..."

# kill a previous instance so the new code is picked up
pkill -f 'server-http\.mjs' >/dev/null 2>&1 || true
sleep 1

cat > "$MCP_DIR/start-http.sh" <<__BEGEMOT_START_HTTP_EOF__
#!/usr/bin/env bash
cd "$MCP_DIR"
export PORT="$HTTP_PORT"
export HOST="127.0.0.1"
exec "$NODE_BIN" server-http.mjs
__BEGEMOT_START_HTTP_EOF__
chmod +x "$MCP_DIR/start-http.sh"

AUTOSTART=""
if [ "$(uname)" = "Darwin" ] && [ -d "$HOME/Library/LaunchAgents" ]; then
    PLIST="$HOME/Library/LaunchAgents/com.begemot.mcp.plist"
    cat > "$PLIST" <<__BEGEMOT_PLIST_EOF__
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.begemot.mcp</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$MCP_DIR/start-http.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$MCP_DIR/http.log</string>
  <key>StandardErrorPath</key><string>$MCP_DIR/http.log</string>
</dict>
</plist>
__BEGEMOT_PLIST_EOF__
    launchctl unload "$PLIST" >/dev/null 2>&1 || true
    if launchctl load "$PLIST" >/dev/null 2>&1; then
        AUTOSTART="launchd ($(basename "$PLIST"))"
    fi
elif command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
    UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/begemot-mcp.service" <<__BEGEMOT_UNIT_EOF__
[Unit]
Description=Begemot MCP Streamable HTTP
After=network.target

[Service]
Type=simple
ExecStart=$MCP_DIR/start-http.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
__BEGEMOT_UNIT_EOF__
    if systemctl --user daemon-reload >/dev/null 2>&1 \
       && systemctl --user enable --now begemot-mcp.service >/dev/null 2>&1; then
        AUTOSTART="systemd --user (begemot-mcp.service)"
    fi
fi

if [ -z "$AUTOSTART" ]; then
    CRON_LINE="@reboot /bin/bash $MCP_DIR/start-http.sh >> $MCP_DIR/http.log 2>&1"
    if crontab -l 2>/dev/null | grep -qF "start-http.sh"; then
        AUTOSTART="crontab @reboot (already present)"
    elif ( crontab -l 2>/dev/null; echo "$CRON_LINE" ) | crontab - 2>/dev/null; then
        AUTOSTART="crontab @reboot"
    fi
fi

if [ -n "$AUTOSTART" ]; then
    ok "autostart: $AUTOSTART"
else
    warn "could not register autostart; starting in background for this boot"
    nohup /bin/bash "$MCP_DIR/start-http.sh" >> "$MCP_DIR/http.log" 2>&1 &
fi

# start now if not already running by autostart
if ! curl -fsS "http://127.0.0.1:$HTTP_PORT/health" >/dev/null 2>&1; then
    nohup /bin/bash "$MCP_DIR/start-http.sh" >> "$MCP_DIR/http.log" 2>&1 &
fi

HEALTH=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    if HEALTH="$(curl -fsS "http://127.0.0.1:$HTTP_PORT/health" 2>/dev/null)"; then
        [ -n "$HEALTH" ] && break
    fi
done
if [ -n "$HEALTH" ]; then ok "health: $HEALTH"
else warn "endpoint not answering yet - see $MCP_DIR/http.log"; fi

# ------------------------------------------------------------
# [7/8] Restart OpenCode service
# ------------------------------------------------------------
step "[7/8] Restarting OpenCode service..."
CLI=""
if command -v opencode >/dev/null 2>&1; then
    CLI="$(command -v opencode)"
elif command -v opencode-cli >/dev/null 2>&1; then
    CLI="$(command -v opencode-cli)"
else
    for P in "/Applications/OpenCode.app/Contents/Resources/opencode-cli" \
             "/Applications/OpenCode.app/Contents/MacOS/opencode-cli" \
             "$HOME/Applications/OpenCode.app/Contents/Resources/opencode-cli"; do
        if [ -x "$P" ]; then CLI="$P"; break; fi
    done
fi
if [ -n "$CLI" ]; then
    if "$CLI" service restart >/dev/null 2>&1; then
        ok "service restarted"
    else
        warn "service restart returned non-zero (restart OpenCode manually)"
    fi
else
    warn "opencode CLI not found - restart the OpenCode app manually"
fi

if [ -n "$CLI" ] && "$CLI" mcp list 2>/dev/null | grep -q "begemot-traffic-light"; then
    ok "begemot-traffic-light connected"
else
    warn "MCP not listed yet - open a new chat / restart OpenCode"
fi

# ------------------------------------------------------------
# [8/8] Self-check: prove the server really starts and answers
# ------------------------------------------------------------
step "[8/8] Self-check..."
if ! "$NODE_BIN" "$MCP_DIR/installer/doctor.mjs" \
        --mcp-dir "$MCP_DIR" --config-dir "$CONFIG_DIR" --http-port "$HTTP_PORT"; then
    err "self-check FAILED - the install does not work yet"
    err "fix the problem marked [FAIL] above, then re-run the installer"
    die "self-check failed"
fi
ok "self-check passed - the MCP server starts and answers"

printf "\n${GREEN}  ============================================${NC}\n"
printf "${GREEN}  INSTALL COMPLETE${NC}\n"
printf "${GREEN}  ============================================${NC}\n"
printf "${CYAN}  MCP server   : %s${NC}\n" "$MCP_DIR"
printf "${CYAN}  Config dir   : %s${NC}\n" "$CONFIG_DIR"
for CF in opencode.jsonc opencode.json; do
    [ -f "$CONFIG_DIR/$CF" ] && printf "${CYAN}  Config file  : %s${NC}\n" "$CF"
done
printf "${CYAN}  Prompt       : %s${NC}\n" "$PROMPT_FILE"
printf "${CYAN}  Plugin       : %s${NC}\n" "$PLUGIN_DIR"
printf "${CYAN}  HTTP endpoint: http://127.0.0.1:%s/mcp  (autostart, no Docker)${NC}\n" "$HTTP_PORT"
printf "${DIM}  remote server config header: \"x-api-key\": \"%s\"${NC}\n" "$API_KEY"
printf "\n${CYAN}  Open a new chat in OpenCode. Begemot is active.${NC}\n\n"
