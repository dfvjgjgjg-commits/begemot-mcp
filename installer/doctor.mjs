#!/usr/bin/env node
/**
 * doctor.mjs - diagnose a Begemot MCP installation.
 *
 * The installer used to end with "OK: connected" and never checked whether the
 * MCP server actually starts. That is exactly why the install worked on one
 * machine and silently did nothing on another. This script proves every link
 * of the chain and prints the FIRST broken one.
 *
 * usage:
 *   node doctor.mjs [--mcp-dir <dir>] [--config-dir <dir>] [--http-port <n>]
 *
 * exit code: 0 = all critical checks passed, 1 = something is broken.
 */

import { spawn, execFileSync } from "child_process";
import { existsSync, readFileSync } from "fs";
import { join, resolve } from "path";

/* ------------------------------------------------------------------ options */

const args = process.argv.slice(2);
function opt(name, fallback) {
  const i = args.indexOf(name);
  if (i !== -1 && args[i + 1]) return args[i + 1];
  const inline = args.find((a) => a.startsWith(name + "="));
  if (inline) return inline.slice(name.length + 1);
  return fallback;
}

const HOME = process.env.USERPROFILE || process.env.HOME || "";
const MCP_DIR = resolve(opt("--mcp-dir", join(HOME, "Documents", "MCP", "begemot-mcp")));
const CONFIG_DIR = resolve(opt("--config-dir", join(HOME, ".config", "opencode")));
const HTTP_PORT = opt("--http-port", "8788");
const NAME = "begemot-traffic-light";

/* ------------------------------------------------------------------ report */

const lines = [];
let failed = 0;

function ok(label, detail) { lines.push(["OK", label, detail]); }
function warn(label, detail) { lines.push(["WARN", label, detail]); }
function bad(label, detail) { lines.push(["FAIL", label, detail]); failed++; }

const TAGS = { OK: "[ OK ]", WARN: "[WARN]", FAIL: "[FAIL]" };

/* -------------------------------------------------------------- jsonc parse */

function stripJsonc(text) {
  let out = "", i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === '"') {
      let j = i + 1;
      while (j < text.length) {
        if (text[j] === "\\") { j += 2; continue; }
        if (text[j] === '"') break;
        j++;
      }
      out += text.slice(i, j + 1); i = j + 1; continue;
    }
    if (c === "/" && text[i + 1] === "/") { while (i < text.length && text[i] !== "\n") i++; continue; }
    if (c === "/" && text[i + 1] === "*") { const e = text.indexOf("*/", i + 2); i = e === -1 ? text.length : e + 2; continue; }
    if (c === ",") {
      let j = i + 1;
      while (j < text.length && /\s/.test(text[j])) j++;
      if (text[j] === "}" || text[j] === "]") { i++; continue; }
    }
    out += c; i++;
  }
  return out;
}

function parseConfig(path) {
  try { return JSON.parse(stripJsonc(readFileSync(path, "utf8"))); } catch { return null; }
}

/* -------------------------------------------------------------------- node */

lines.push(["HEAD", "BEGEMOT MCP - DOCTOR", ""]);

ok("node", process.version + "  (" + process.execPath + ")");

let npmVersion = null;
try {
  const npmCmd = process.platform === "win32"
    ? { file: "cmd.exe", args: ["/c", "npm", "--version"] }
    : { file: "npm", args: ["--version"] };
  npmVersion = execFileSync(npmCmd.file, npmCmd.args, { encoding: "utf8", timeout: 30000 }).trim();
  ok("npm", npmVersion);
} catch {
  warn("npm", "not reachable - the server dependencies cannot be installed");
}

/* -------------------------------------------------------------------- files */

const required = ["core.mjs", "server.js", "server-http.mjs"];
const missing = required.filter((f) => !existsSync(join(MCP_DIR, f)));
if (missing.length) bad("files", "missing in " + MCP_DIR + ": " + missing.join(", "));
else ok("files", required.join(", ") + "  (" + MCP_DIR + ")");

const sdkDir = join(MCP_DIR, "node_modules", "@modelcontextprotocol", "sdk");
if (!existsSync(sdkDir)) {
  bad("sdk", "@modelcontextprotocol/sdk is missing - run: cd \"" + MCP_DIR + "\" && npm install");
} else {
  let v = "";
  try { v = JSON.parse(readFileSync(join(sdkDir, "package.json"), "utf8")).version; } catch {}
  ok("sdk", "@modelcontextprotocol/sdk " + v);
}

const promptPath = join(CONFIG_DIR, "begemot_prompt.md");
if (existsSync(promptPath)) ok("prompt", promptPath);
else bad("prompt", "missing " + promptPath + " (the system rules would not load)");

const pluginIndex = join(CONFIG_DIR, "plugins", "greenlight", "index.js");
if (existsSync(pluginIndex)) ok("plugin", pluginIndex);
else bad("plugin", "missing " + pluginIndex + " (the green-light directive would not load)");

/* ------------------------------------------------------------------- config */

const configFiles = ["opencode.jsonc", "opencode.json"]
  .map((f) => join(CONFIG_DIR, f))
  .filter((p) => existsSync(p));

if (!configFiles.length) {
  bad("config", "no opencode.jsonc / opencode.json in " + CONFIG_DIR);
} else {
  for (const cf of configFiles) {
    const cfg = parseConfig(cf);
    if (!cfg) { bad("config", cf + " is not parseable JSON(C)"); continue; }
    const nested = cfg?.mcp?.servers?.[NAME];
    const flat = cfg?.mcp?.[NAME];
    const entry = nested || flat;
    if (!entry) {
      bad("config", cf + " has no \"" + NAME + "\" entry under mcp.servers or mcp");
      continue;
    }
    const shape = nested ? "nested (mcp.servers)" : "flat (mcp.<name>)";
    const cmd = Array.isArray(entry.command) ? entry.command : [];
    const script = cmd[1] || "";
    if (!cmd.length) { bad("config", cf + ": entry has no command"); continue; }
    if (script && !existsSync(script)) {
      bad("config", cf + ": command points at a missing file: " + script);
      continue;
    }
    if (cmd[0] && !existsSync(cmd[0])) {
      bad("config", cf + ": node executable is missing: " + cmd[0]);
      continue;
    }
    ok("config", cf + "  [" + shape + "]  node=" + (cmd[0] || "?"));
  }
}

/* ------------------------------------------------------------ stdio self-test */

function stdioSelfTest(serverPath, cwd) {
  return new Promise((resolvePromise) => {
    let child;
    try {
      child = spawn(process.execPath, [serverPath], { cwd, stdio: ["pipe", "pipe", "pipe"] });
    } catch (e) {
      return resolvePromise({ ok: false, reason: "cannot spawn: " + e.message });
    }
    let buf = "";
    let stderr = "";
    const seen = new Map();
    let done = false;

    const finish = (res) => {
      if (done) return;
      done = true;
      try { child.kill(); } catch {}
      resolvePromise(res);
    };
    const timer = setTimeout(() => {
      finish({ ok: false, reason: "timeout waiting for the MCP handshake", stderr: stderr.slice(-400) });
    }, 25000);

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      buf += chunk;
      let idx;
      while ((idx = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, idx).trim();
        buf = buf.slice(idx + 1);
        if (!line) continue;
        let msg;
        try { msg = JSON.parse(line); } catch { continue; }
        if (msg.id && seen.has(msg.id)) continue;
        if (msg.id) seen.set(msg.id, msg);
      }
      if (seen.has(1) && !child._initialized) {
        child._initialized = true;
        send({ jsonrpc: "2.0", method: "notifications/initialized" });
        send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
      }
      if (seen.has(2) && !child._listed) {
        child._listed = true;
        send({
          jsonrpc: "2.0", id: 3, method: "tools/call",
          params: { name: "check_traffic_light", arguments: { request_completed: true } },
        });
      }
      if (seen.has(3)) {
        clearTimeout(timer);
        const toolNames = seen.get(2)?.result?.tools?.map((t) => t.name) || [];
        const r = seen.get(3);
        if (r.error) {
          finish({ ok: false, reason: "check_traffic_light error: " + JSON.stringify(r.error), tools: toolNames.length });
        } else {
          const text = (r.result?.content || []).map((c) => c.text || "").join(" ");
          finish({
            ok: true,
            reason: "check_traffic_light answered",
            tools: toolNames.length,
            excerpt: text.slice(0, 120).replace(/\s+/g, " "),
            stderr: stderr.slice(-200),
          });
        }
      }
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("error", (e) => { clearTimeout(timer); finish({ ok: false, reason: "spawn error: " + e.message }); });
    child.on("exit", (code) => {
      clearTimeout(timer);
      if (!seen.has(3)) finish({ ok: false, reason: "server exited with code " + code, stderr: stderr.slice(-400) });
    });

    function send(obj) {
      try { child.stdin.write(JSON.stringify(obj) + "\n"); } catch {}
    }
    send({
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "begemot-doctor", version: "1.0.0" },
      },
    });
  });
}

const serverPath = join(MCP_DIR, "server.js");
if (existsSync(serverPath)) {
  const res = await stdioSelfTest(serverPath, MCP_DIR);
  if (res.ok) {
    ok("stdio", "initialize + tools/list (" + res.tools + " tools) + check_traffic_light -> " + res.reason);
    if (res.excerpt) lines.push(["RAW", "             ", res.excerpt]);
  } else {
    bad("stdio", res.reason + (res.stderr ? " | " + res.stderr.replace(/\s+/g, " ").slice(0, 300) : ""));
  }
} else {
  bad("stdio", "server.js not found in " + MCP_DIR);
}

/* ---------------------------------------------------------------- http (opt) */

try {
  const r = await fetch("http://127.0.0.1:" + HTTP_PORT + "/health", { signal: AbortSignal.timeout(3000) });
  const t = await r.text();
  ok("http", "127.0.0.1:" + HTTP_PORT + " -> " + t.slice(0, 120));
} catch {
  warn("http", "127.0.0.1:" + HTTP_PORT + " not answering (the HTTP mode is optional)");
}

/* --------------------------------------------------------- opencode registry */

let cli = null;
const cliCandidates = [];
if (process.platform === "win32") {
  const local = process.env.LOCALAPPDATA || "";
  cliCandidates.push(join(local, "Programs", "@opencodedesktop", "resources", "opencode-cli.exe"));
  cliCandidates.push(join(local, "Programs", "opencode", "bin", "opencode.exe"));
} else {
  cliCandidates.push("/usr/local/bin/opencode", "/usr/bin/opencode");
}
for (const c of cliCandidates) if (existsSync(c)) { cli = c; break; }
if (!cli) {
  try {
    const which = execFileSync(process.platform === "win32" ? "where" : "which", ["opencode"], { encoding: "utf8" }).trim().split(/\r?\n/)[0];
    if (which && existsSync(which)) cli = which;
  } catch { /* not on PATH */ }
}

if (!cli) {
  warn("opencode", "the opencode CLI was not found - the MCP entry is written but not verified");
} else {
  try {
    const out = execFileSync(cli, ["mcp", "list"], { encoding: "utf8", timeout: 90000 });
    if (out.includes(NAME)) ok("opencode", "mcp list reports " + NAME);
    else warn("opencode", "mcp list does not show " + NAME + " yet - restart OpenCode\n" + out.trim());
  } catch (e) {
    warn("opencode", "mcp list failed: " + (e.stdout || e.message).toString().slice(0, 200));
  }
}

/* -------------------------------------------------------------------- print */

for (const [tag, label, detail] of lines) {
  if (tag === "HEAD") {
    console.log("\n" + label + "\n" + "=".repeat(label.length));
    continue;
  }
  console.log(TAGS[tag] ? TAGS[tag] + " " : "") + label.padEnd(12) + " " + detail;
}
console.log("");
console.log(failed ? "RESULT: FAIL (" + failed + " critical problem(s))" : "RESULT: PASS");
process.exit(failed ? 1 : 0);
