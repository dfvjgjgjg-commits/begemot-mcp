#!/usr/bin/env bash
# ============================================================
#  BEGEMOT MCP - OpenCode Uninstaller (macOS / Linux)
#  Removes everything the auto-installer put in place, in reverse order,
#  and leaves the user's own configuration untouched:
#
#    - stops the HTTP endpoint and removes its autostart
#      (launchd agent / systemd user unit / crontab @reboot line)
#    - removes OUR entries from opencode.json / opencode.jsonc, textually and
#      surgically: comments, key order, formatting and the user's own servers,
#      instructions and plugins survive
#    - deletes the prompt, the greenlight plugin and the deployed server tree
#    - keeps the .bak.<timestamp> config backups unless PURGE_BACKUPS=1
#
#  Idempotent: running it on a machine with nothing installed changes nothing.
#
#  One-liner:
#    curl -fsSL https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/uninstall_begemot_opencode.sh | bash
#  With a full purge (also deletes the config backups):
#    curl -fsSL https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/uninstall_begemot_opencode.sh | PURGE_BACKUPS=1 bash
# ============================================================
set -uo pipefail

REPO_OWNER="dfvjgjgjg-commits"
REPO_NAME="begemot-mcp"
BRANCH="main"
HTTP_PORT="${BEGEMOT_HTTP_PORT:-8788}"
SERVER_NAME="begemot-traffic-light"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
MCP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/begemot-mcp"
PROMPT_FILE="$CONFIG_DIR/begemot_prompt.md"
PLUGIN_DIR="$CONFIG_DIR/plugins/greenlight"

PLIST="$HOME/Library/LaunchAgents/com.begemot.mcp.plist"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/begemot-mcp.service"

PURGE_BACKUPS="${PURGE_BACKUPS:-0}"
KEEP_SERVER_DIR="${KEEP_SERVER_DIR:-0}"

GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; CYAN='\033[36m'; DIM='\033[90m'; NC='\033[0m'

ok()   { printf "${GREEN}  OK: %s${NC}\n" "$1"; }
skip() { printf "${DIM}  --: %s${NC}\n" "$1"; }
warn() { printf "${YELLOW}  WARN: %s${NC}\n" "$1"; }
err()  { printf "${RED}  ERROR: %s${NC}\n" "$1" >&2; }
die()  { printf "${RED}  ERROR: %s${NC}\n" "$1" >&2; exit 1; }
step() { printf "\n${YELLOW}%s${NC}\n" "$1"; }

printf "\n${RED}  ============================================${NC}\n"
printf "${RED}  BEGEMOT MCP - OpenCode Uninstaller${NC}\n"
printf "${DIM}  your own config is left untouched${NC}\n"
printf "${RED}  ============================================${NC}\n"

TMP_BEGEMOT="$(mktemp -d 2>/dev/null || mktemp -d -t begemot)"
trap 'rm -rf "$TMP_BEGEMOT"' EXIT

config_has_begemot() {
    [ -f "$1" ] || return 1
    grep -q "$SERVER_NAME" "$1" 2>/dev/null && return 0
    grep -q "begemot_prompt" "$1" 2>/dev/null && return 0
    grep -q "greenlight" "$1" 2>/dev/null && return 0
    return 1
}

# ------------------------------------------------------------
# [1/5] What is actually installed here
# ------------------------------------------------------------
step "[1/5] Looking for an existing install..."

FOUND=0
[ -d "$MCP_DIR" ]     && { printf "${DIM}  found server tree : %s${NC}\n" "$MCP_DIR"; FOUND=1; }
[ -f "$PROMPT_FILE" ] && { printf "${DIM}  found prompt      : %s${NC}\n" "$PROMPT_FILE"; FOUND=1; }
[ -d "$PLUGIN_DIR" ]  && { printf "${DIM}  found plugin      : %s${NC}\n" "$PLUGIN_DIR"; FOUND=1; }
[ -f "$PLIST" ]       && { printf "${DIM}  found autostart   : launchd agent${NC}\n"; FOUND=1; }
[ -f "$UNIT" ]        && { printf "${DIM}  found autostart   : systemd user unit${NC}\n"; FOUND=1; }
if crontab -l 2>/dev/null | grep -qF "start-http.sh"; then
    printf "${DIM}  found autostart   : crontab @reboot line${NC}\n"; FOUND=1
fi

CFG_FILES=""
for CF in "$CONFIG_DIR/opencode.jsonc" "$CONFIG_DIR/opencode.json"; do
    if config_has_begemot "$CF"; then
        printf "${DIM}  found config      : %s${NC}\n" "$CF"
        CFG_FILES="$CFG_FILES $CF"
        FOUND=1
    fi
done

if [ "$FOUND" -eq 0 ]; then
    skip "nothing of Begemot is installed - nothing to remove"
    printf "\n"
    exit 0
fi

# ------------------------------------------------------------
# [2/5] Stop the HTTP endpoint and drop its autostart
# ------------------------------------------------------------
step "[2/5] Stopping the HTTP endpoint..."

if [ "$(uname)" = "Darwin" ] && [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    ok "launchd agent removed"
elif [ -f "$UNIT" ]; then
    systemctl --user disable --now begemot-mcp.service >/dev/null 2>&1 || true
    rm -f "$UNIT"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    ok "systemd user unit removed"
fi

if crontab -l 2>/dev/null | grep -qF "start-http.sh"; then
    crontab -l 2>/dev/null | grep -vF "start-http.sh" | crontab - 2>/dev/null \
        && ok "crontab @reboot line removed" \
        || warn "could not update crontab - remove the start-http.sh line by hand"
fi

if pkill -f 'server-http\.mjs' >/dev/null 2>&1; then
    sleep 1
    pkill -9 -f 'server-http\.mjs' >/dev/null 2>&1 || true
    ok "server process stopped"
else
    skip "no server process running"
fi

if curl -fsS --max-time 2 "http://127.0.0.1:$HTTP_PORT/health" >/dev/null 2>&1; then
    warn "port $HTTP_PORT still answers - another program may be using it"
else
    skip "port $HTTP_PORT is free"
fi

# ------------------------------------------------------------
# [3/5] Clean the OpenCode config (surgical, comments preserved)
# ------------------------------------------------------------
step "[3/5] Cleaning the OpenCode config..."

NODE_BIN="$(command -v node || true)"

if [ -n "${CFG_FILES// }" ] && [ -n "$NODE_BIN" ]; then
    # The removal module ships next to the installer in the deployed tree.
    # Older installs do not have it, so fetch it (and the scanner it imports)
    # from GitHub into the temp dir and use that instead.
    WORK_DIR=""
    if [ -f "$MCP_DIR/installer/unmerge-opencode-config.mjs" ]; then
        WORK_DIR="$MCP_DIR/installer"
        skip "using the deployed removal module"
    else
        WORK_DIR="$TMP_BEGEMOT"
        for MOD in unmerge-opencode-config.mjs merge-opencode-config.mjs; do
            curl -fsSL "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$BRANCH/installer/$MOD" \
                -o "$WORK_DIR/$MOD" 2>/dev/null || die "cannot obtain $MOD - nothing was removed from the config"
            ok "$MOD fetched from GitHub"
        done
    fi

    for CF in $CFG_FILES; do
        BACKUP="$CF.bak.$(date +%Y%m%d%H%M%S)"
        cp "$CF" "$BACKUP" 2>/dev/null && printf "${DIM}  backup: %s${NC}\n" "$BACKUP"
    done

    "$NODE_BIN" "$WORK_DIR/unmerge-opencode-config.mjs" "$CONFIG_DIR" "$PROMPT_FILE" "$PLUGIN_DIR" \
        || die "config cleanup failed"
    ok "Begemot entries removed from the config, everything else kept"
elif [ -n "${CFG_FILES// }" ]; then
    warn "node not found - remove the Begemot entries from your opencode config by hand"
else
    skip "config has no Begemot entries"
fi

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
    "$CLI" service restart >/dev/null 2>&1 || true
    skip "OpenCode service restarted so it reloads the config"
fi

# ------------------------------------------------------------
# [4/5] Remove the files
# ------------------------------------------------------------
step "[4/5] Removing files..."

if [ -f "$PROMPT_FILE" ]; then
    rm -f "$PROMPT_FILE" && ok "prompt removed" || warn "could not remove the prompt"
else
    skip "no prompt file"
fi

if [ -d "$PLUGIN_DIR" ]; then
    rm -rf "$PLUGIN_DIR" && ok "plugin removed" || warn "could not remove the plugin"
else
    skip "no plugin"
fi

if [ -d "$MCP_DIR" ]; then
    if [ "$KEEP_SERVER_DIR" = "1" ]; then
        skip "server tree kept (KEEP_SERVER_DIR=1): $MCP_DIR"
    else
        rm -rf "$MCP_DIR" && ok "server tree removed: $MCP_DIR" \
            || warn "could not fully remove $MCP_DIR"
    fi
else
    skip "no server tree"
fi

# drop the now-empty parents we created, but never $HOME/.config itself
rmdir "$CONFIG_DIR/plugins" 2>/dev/null || true

if [ "$PURGE_BACKUPS" = "1" ]; then
    BAKS="$(ls "$CONFIG_DIR"/opencode.json*.bak.* 2>/dev/null || true)"
    if [ -n "$BAKS" ]; then
        rm -f $BAKS && ok "config backups purged"
    else
        skip "no backups to purge"
    fi
fi

# ------------------------------------------------------------
# [5/5] Verify
# ------------------------------------------------------------
step "[5/5] Verifying..."

LEFT=""
[ -d "$MCP_DIR" ]     && LEFT="$LEFT server-tree"
[ -f "$PROMPT_FILE" ] && LEFT="$LEFT prompt"
[ -d "$PLUGIN_DIR" ]  && LEFT="$LEFT plugin"
[ -f "$PLIST" ]       && LEFT="$LEFT launchd-agent"
[ -f "$UNIT" ]        && LEFT="$LEFT systemd-unit"
for CF in "$CONFIG_DIR/opencode.jsonc" "$CONFIG_DIR/opencode.json"; do
    config_has_begemot "$CF" && LEFT="$LEFT "$(basename "$CF")
done
if pgrep -f 'server-http\.mjs' >/dev/null 2>&1; then LEFT="$LEFT running-process"; fi
if crontab -l 2>/dev/null | grep -qF "start-http.sh"; then LEFT="$LEFT crontab-line"; fi

printf "\n"
if [ -n "$LEFT" ]; then
    warn "remaining:$LEFT"
    printf "${YELLOW}  Some pieces are still there - see the WARN line above.${NC}\n"
else
    printf "${GREEN}  ============================================${NC}\n"
    printf "${GREEN}  UNINSTALL COMPLETE - nothing left behind${NC}\n"
    printf "${GREEN}  ============================================${NC}\n"
    printf "${CYAN}  Your own servers, rules and plugins were not touched.${NC}\n"
    if [ "$PURGE_BACKUPS" != "1" ]; then
        printf "${DIM}  Config backups are kept: $CONFIG_DIR/opencode.json*.bak.*${NC}\n"
        printf "${DIM}  (re-run with PURGE_BACKUPS=1 to delete them)${NC}\n"
    fi
    printf "${CYAN}  To install again:${NC}\n"
    printf "${DIM}  curl -fsSL https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$BRANCH/installer/install_begemot_opencode.sh | bash${NC}\n"
fi
printf "\n"
