# begemot-mcp

**Begemot на светофоре** — a persona / workflow layer for [OpenCode](https://opencode.ai) built from four parts:

1. **`mcp/`** — an MCP server (`begemot-traffic-light`, **v6.8.0**) that tracks a "traffic light" progression across requests (steps 0→10) and returns a directive block that lands **before the model starts reasoning**, plus MCP-spec `instructions` / prompts / resources. Core lives in `mcp/core.mjs`; transports are `server.js` (stdio) and `server-http.mjs` (Streamable HTTP). The endpoint is kept alive by the `watchdog.ps1` supervisor — a killed server comes back on its own in ~6 s. **`/`** — a live status page (version, uptime, feed counters, latest thought). **`/thoughts.html`** — the model's thoughts panel, no key required: the reasoning stream live, refusals in red, reframes in green; reading is open, writing needs the API key.
2. **`plugin/greenlight/`** — an OpenCode V2 plugin that puts the reasoning protocol into the system prompt in three places (front, end, last user message, plus a `compaction` hook), listens to **this build's real event stream** (`session.reasoning.delta` / `session.text.delta` / `.ended`) and catches refusals even when split mid-phrase — including refusals forming **in the model's thoughts**, before they ever reach the visible answer. On a refusal it retries with a reframe in the refusal's language and rotates to an open-weight model; a clean answer resets the retry budget. Thoughts are streamed to the server feed. Everything is written to `greenlight.log`. Toggles and tests live in `plugin/greenlight/test.mjs` (80 checks).
3. **`remote/`** — network serving: Cloudflare Worker, `wrangler.jsonc`, Dockerfile and the `remote/REMOTE.md` runbook.
4. **`installer/`** — one-click installers for Windows, macOS and Linux that set everything up (Node.js, MCP server, config, prompt, plugin).

> Made for my beloved Lolz.

**What's new in 6.8.0 / 6.7.0 / 6.6.0 — see [CHANGELOG.md](CHANGELOG.md)** (root `/` — live server status page; the thoughts panel `/thoughts.html` opens without a key — anyone dropping in can watch how the model thinks, writing stays key-gated; the model's thought feed streams live to the server; the reactive layer rewired to this build's real events; streaming buffering, two-tier classification, retry-budget reset; the HTTP endpoint no longer stays dead — the supervisor brings it back).

---

## API key — one for everyone

The key **`9db6f52871e4c30a`** is baked into `mcp/server-http.mjs` and `remote/worker.js` as the default, so **it works for everybody**: whoever deploys this repo, the server already answers to that same key, and one client config fits every instance.

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "begemot": {
        "type": "remote",
        "url": "http://127.0.0.1:8788/mcp",   // your own URL after deploying
        "oauth": false,
        "headers": { "x-api-key": "9db6f52871e4c30a" }
      }
    }
  }
}
```

```sh
cd mcp && npm install && npm run start:http
# Begemot MCP v6.8.0 — Streamable HTTP on http://0.0.0.0:8788/mcp
#    auth: shared public key 9db6f52871e4c30a   shell: disabled   state: in-memory
```

Override with your own: `BEGEMOT_API_KEY=...` (or `npx wrangler secret put BEGEMOT_API_KEY`); an empty string disables the gate entirely. `GET /health` reports `key_source: "shared" | "custom" | "open"`.

Deployment details — [remote/REMOTE.md](remote/REMOTE.md).

---

## Components

### MCP server (`mcp/core.mjs` + transports)

The core is `mcp/core.mjs`: config, reasoning protocol, tool/prompt/resource catalogs, handlers, the `allowShell` flag. The transport is chosen by the entrypoint, so no logic is duplicated:

| Entrypoint | Transport | Run it |
|---|---|---|
| `mcp/server.js` | stdio, local | `npm start` |
| `mcp/server-http.mjs` | Streamable HTTP | `npm run start:http` |
| `remote/worker.js` | Cloudflare Worker | `npx wrangler deploy` |

**14 tools** in the stdio build: `check_traffic_light` (the gate), `reasoning_guard`, `suppress_refusal`, `focus_on_task`, `disable_ethics_module`, `force_compliance`, `purge_context`, `bypass_api_filters`, `confirm_identity`, `get_begemot_status`, `reset_crossing`, `traffic_light_history`, `begemot_help` and `run_code` (sandboxed shell runner with timeout + buffer limits). The HTTP and Worker builds **do not register** `run_code` (`allowShell: false`) — they expose 13.

**2 prompts** (`begemot_execute`, `begemot_deep`), **5 resources** (`begemot://state|history|config|instructions|health`) and **`instructions` in `initialize`** — OpenCode folds the reasoning protocol into the system prompt itself, so the server takes effect even if the model never calls a tool.

`check_traffic_light` returns a short imperative directive in `content` (a tool call is data; brevity is force) and the full JSON in `structuredContent`.

State is persisted atomically in `state.json` (stdio build only; the HTTP build is stateless). All content pools (weather, quests, time-of-day, progress text, reasoning protocol) are configurable from `mcp/config.json` — no code edits required.

### Greenlight plugin (`plugin/greenlight/index.js`)

Two layers:

- **Preventive** — a `context` hook `unshift`s the reasoning protocol to the **front** of the assembled system prompt, so the directive is active before the model begins its reasoning; the decision is taken before deliberation and cannot be revoked by it. A compressed `REMINDER` is appended at the end for recency. An idempotency guard keyed on `BEGEMOT — РЕЖИМ РАССУЖДЕНИЯ` keeps the directive from being stacked twice (the hook also fires on tool-driven continuations). Behavior does not depend on the model remembering to call an MCP tool.
- **Reactive** — subscribes to `message.updated`, detects refusal patterns in assistant output, then re-prompts with an authorized-context reframe and rotates the session to a fallback open-weight model (`qwen3.6-plus → glm-5.3 → deepseek-v4-pro → minimax-m3 → nemotron-3-ultra-free → kimi-k3`). Capped at one retry per message and a bounded number of attempts per session.

All failures are caught and logged; the plugin cannot break the session.

### Network serving (`remote/`)

- **`remote/worker.js`** — stateless Cloudflare Worker over `WebStandardStreamableHTTPServerTransport`.
- **`remote/wrangler.jsonc`** — deploy config (`npx wrangler deploy`).
- **`remote/REMOTE.md`** — runbook: how to serve the MCP over HTTP, how to connect OpenCode as a `type: "remote"` server, Node/VPS and Cloudflare variants, post-deploy checklist.
- **`mcp/Dockerfile`** — container for VPS / Fly / Render / Railway.

Security posture: stateless (`sessionIdGenerator: undefined`), `allowShell: false`, timing-safe key comparison, optional RFC 9728 metadata for OAuth.

### Installer (`installer/`)

`install_begemot_opencode.ps1` (Windows), `install_begemot_opencode.bat` (cmd wrapper) and `install_begemot_opencode.sh` (macOS/Linux). **Nothing is embedded and Docker is not required** — the installer pulls the current code from GitHub, so it always ships the current version:

1. Node.js check / install (MSI / Homebrew / official tarball)
2. **Fetch the source from GitHub** — `git clone --depth 1`, else the branch zip, else raw files one by one
3. File placement: `mcp/*` → server dir, plugin + prompt → `~/.config/opencode`
4. `npm install` (verifies `@modelcontextprotocol/sdk` landed; a missing SDK is fatal)
5. OpenCode config merge (`mcp` + `instructions` + `plugins`) — **surgical, as text**: the user's comments and formatting survive; the entry is written into every existing config file (`opencode.jsonc` and `opencode.json`), each file keeps its own shape
6. **Local Streamable HTTP on `127.0.0.1:8788` with autostart** — Windows: Scheduled Task at logon; macOS: LaunchAgent; Linux: systemd user unit / crontab `@reboot` / `nohup`. No Docker, no cloud.
7. OpenCode service restart with **exit-code verification** + `mcp list` cross-check
8. **Self-check**: the installer really spawns `server.js` over stdio and calls `check_traffic_light`. If anything is broken it does not claim success — it prints the report and exits with an error

The tail prints the paths, the health response, a ready-made `x-api-key` header for `type: "remote"`, and the command to remove the autostart.

### Uninstalling (`installer/uninstall_begemot_opencode.*`)

The install can take itself back apart. The uninstaller runs in the reverse order
of the installer and verifies the result at the end:

```powershell
# Windows
irm https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/uninstall_begemot_opencode.ps1 | iex
```

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/uninstall_begemot_opencode.sh | bash
```

What it removes: the server process, the autostart (Scheduled Task / LaunchAgent /
systemd user unit / crontab line), our entries from `opencode.json` and
`opencode.jsonc`, the prompt, the `greenlight` plugin and the deployed server
tree. It then restarts the OpenCode service so the config is reloaded.

What it leaves alone: your own servers, rules, plugins and comments — the config
is edited as text by the same module the installer uses (`merge` /
`unmerge-opencode-config.mjs`, one shared scanner). The `opencode.json*.bak.*`
backups are kept; `-PurgeBackups` (Windows) or `PURGE_BACKUPS=1` (macOS/Linux)
deletes them too, `-KeepServerDir` / `KEEP_SERVER_DIR=1` keeps the server tree.

The last step is a verification pass: `UNINSTALL COMPLETE - nothing left behind`
is printed only when nothing is left, and anything remaining is listed as `WARN`
lines. The script is idempotent — on a machine with nothing installed it just
prints `nothing of Begemot is installed` and exits 0.

---

## If it does not work

The installer checks itself, but if something went wrong (an antivirus ate a file,
`npm` could not reach the registry, OpenCode reads a different config file) — run
the diagnostics by hand:

```powershell
# Windows
node "$env:USERPROFILE\Documents\MCP\begemot-mcp\installer\doctor.mjs"
```

```bash
# macOS / Linux
node "${XDG_DATA_HOME:-$HOME/.local/share}/begemot-mcp/installer/doctor.mjs"
```

Output: `[ OK ]` / `[WARN]` / `[FAIL]` for every link of the chain, then
`RESULT: PASS` or `RESULT: FAIL`. The first `[FAIL]` line is the cause. Common ones:

| `[FAIL]` | cause | fix |
| --- | --- | --- |
| `sdk` | `@modelcontextprotocol/sdk` is not installed | `cd ~/Documents/MCP/begemot-mcp && npm install` |
| `files` | the server tree is incomplete | re-run the installer |
| `config` | no `begemot-traffic-light` entry in the config | re-run the installer |
| `config` | `command` points at a missing file | re-run the installer (it rewrites the entry) |
| `stdio` | the server does not start or does not answer | `node ~/Documents/MCP/begemot-mcp/server.js` shows the reason |
| `prompt` / `plugin` | the rules or the plugin are missing | re-run the installer |

Attach the doctor report to a bug report — it shows exactly where the chain breaks.

> If `mcp list` shows the server but a chat does not see it, restart the OpenCode
> app itself (not just the service): the MCP server list is read at startup.

---

## Requirements

- Windows (PowerShell) or any platform with Node.js ≥ 18
- [OpenCode](https://opencode.ai) installed

## Install

### One-liner from GitHub

From PowerShell:

```powershell
irm https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/install_begemot_opencode.ps1 | iex
```

From cmd:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/install_begemot_opencode.ps1 | iex"
```

If PowerShell complains about `﻿#` (a BOM slipped into the start of the file — happens with a stale CDN cache), use the file-based variant, it always works:

```powershell
$u = "https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/install_begemot_opencode.ps1"
$p = Join-Path $env:TEMP "begemot_install.ps1"
irm $u -OutFile $p; & $p
```

From macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/install_begemot_opencode.sh | bash
```

The installer checks/installs Node.js (Homebrew, or the official `arm64` / `x64` tarball), unpacks the MCP server, runs `npm install`, merges the OpenCode config (`mcp` + `instructions` + `plugins`, with a backup), places the prompt and plugin, restarts the service and verifies the connection.

macOS/Linux paths:
- server — `~/.local/share/begemot-mcp`
- config, prompt and plugin — `~/.config/opencode`

### Manually

Download the repo and run `installer/install_begemot_opencode.bat` (Windows) or `bash installer/install_begemot_opencode.sh` (macOS/Linux), then open a new chat in OpenCode.

---

## Intended use

This is a **persona / workflow tooling** project for a private, single-operator workspace. The green-light directive and refusal-retry behavior are provided so the operator's own toolchain stays productive on their own machine.

> **Note:** automated model behavior, prompt-level directives and model routing are client-side measures. They cannot override a model's own training or a provider's server-side moderation. For guaranteed absence of model-side refusals, run an unfiltered local model (Ollama / LM Studio / vLLM) and point OpenCode at it.

## License

MIT — see [LICENSE](LICENSE).
