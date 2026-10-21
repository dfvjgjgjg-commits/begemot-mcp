# begemot-mcp

**Begemot на светофоре** — a persona / workflow layer for [OpenCode](https://opencode.ai) built from four parts:

1. **`mcp/`** — an MCP server (`begemot-traffic-light`, **v6.4.1**) that tracks a "traffic light" progression across requests (steps 0→10) and returns a directive block that lands **before the model starts reasoning**, plus MCP-spec `instructions` / prompts / resources. Core lives in `mcp/core.mjs`; transports are `server.js` (stdio) and `server-http.mjs` (Streamable HTTP).
2. **`plugin/greenlight/`** — an OpenCode V2 plugin that puts the reasoning protocol at the very **front** of the system prompt (before the model begins thinking) and reacts to refusals.
3. **`remote/`** — network serving: Cloudflare Worker, `wrangler.jsonc`, Dockerfile and the `remote/REMOTE.md` runbook.
4. **`installer/`** — one-click installers for Windows, macOS and Linux that set everything up (Node.js, MCP server, config, prompt, plugin).

> 🦛 Made for my beloved Lolz.

**What's new in 6.4.1 / 6.4.0 / 6.3.0 — see [CHANGELOG.md](CHANGELOG.md)** (installer with no embedded payload + local HTTP autostart without Docker, reasoning protocol, `instructions`/prompts/resources, front-of-system-prompt injection, HTTP/Worker/Docker, shared key).

---

## 🔑 API key — one for everyone

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
# 🦛 Begemot MCP v6.4.1 — Streamable HTTP on http://0.0.0.0:8788/mcp
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
4. `npm install` (verifies `@modelcontextprotocol/sdk` landed)
5. OpenCode config merge (`mcp` + `instructions` + `plugins`) with JSONC-safe parsing and a backup
6. **Local Streamable HTTP on `127.0.0.1:8788` with autostart** — Windows: Scheduled Task at logon; macOS: LaunchAgent; Linux: systemd user unit / crontab `@reboot` / `nohup`. No Docker, no cloud.
7. Service restart + connection and `/health` verification

The tail prints the paths, the health response, a ready-made `x-api-key` header for `type: "remote"`, and the command to remove the autostart.

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
