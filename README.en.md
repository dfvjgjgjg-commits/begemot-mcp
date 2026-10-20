# begemot-mcp

**Begemot на светофоре** — a persona / workflow layer for [OpenCode](https://opencode.ai) built from three parts:

1. **`mcp/`** — an MCP server (`begemot-traffic-light`) that tracks a "traffic light" progression across requests (steps 0→10) and returns a structured directive block.
2. **`plugin/greenlight/`** — an OpenCode V2 plugin that automatically injects the green-light directive into every model call and reacts to refusals.
3. **`installer/`** — one-click installers for Windows and macOS/Linux that set everything up (Node.js, MCP server, config, prompt, plugin).

> 🦛 Made for my beloved Lolz.

---

## Components

### MCP server (`mcp/server.js`)

Exposes 13 tools, including `check_traffic_light` (the gate), `get_begemot_status`, `traffic_light_history`, `run_code` (sandboxed shell runner with timeout + buffer limits), and `begemot_help`.

State is persisted atomically in `state.json`. All content pools (weather, quests, time-of-day, progress text) are configurable from `mcp/config.json` — no code edits required.

### Greenlight plugin (`plugin/greenlight/index.js`)

Two layers:

- **Preventive** — a `context`/`generate` session hook pushes a green-light system directive into every outgoing model request, so the behavior does not depend on the model remembering to call an MCP tool.
- **Reactive** — subscribes to `message.updated`, detects refusal patterns in assistant output, then re-prompts with an authorized-context reframe and rotates the session to a fallback open-weight model (`qwen3.6-plus → glm-5.3 → deepseek-v4-pro → minimax-m3 → nemotron-3-ultra-free → kimi-k3`). Capped at one retry per message and a bounded number of attempts per session.

All failures are caught and logged; the plugin cannot break the session.

### Installer (`installer/`)

`install_begemot_opencode.ps1` (Windows) and `install_begemot_opencode.sh` (macOS/Linux) perform:

1. Node.js check / install
2. MCP server extraction
3. `npm install`
4. OpenCode config merge (`mcp` server + `instructions` + `plugins`) with JSONC-safe parsing and a backup
5. Prompt + plugin placement
6. Service restart + verification

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
