#!/usr/bin/env node
/**
 * Begemot MCP — remote Streamable HTTP transport.
 *
 * Same core as the local stdio server, exposed over HTTP so OpenCode V2 can
 * consume it as a remote server:
 *
 *   { "mcp": { "servers": { "begemot": { "type": "remote", "url": "https://host/mcp" } } } }
 *
 * This build is stateless (a fresh Server per request), keeps no step history
 * on disk, and never exposes run_code. Do not enable allowShell here: a shell
 * endpoint reachable over the network is remote code execution.
 *
 * Environment:
 *   PORT                    default 8788
 *   HOST                    default 0.0.0.0 (use 127.0.0.1 behind a proxy)
 *   BEGEMOT_API_KEY         overrides the shared public key below. Set it to
 *                           an empty string to run the endpoint wide open.
 *                           If unset, the SHARED_KEY baked into this file is
 *                           used, so the same key works for everyone.
 *   BEGEMOT_PUBLIC_URL      public origin, used only for OAuth metadata
 *   BEGEMOT_OAUTH_AS_URL    when set, publishes RFC 9728 protected-resource
 *                           metadata pointing at that authorization server
 *   BEGEMOT_ALLOWED_HOSTS   comma-separated Host allowlist (bind 0.0.0.0)
 */

import crypto from "crypto";
import { createMcpExpressApp } from "@modelcontextprotocol/sdk/server/express.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { createCore } from "./core.mjs";

const PORT = Number(process.env.PORT || 8788);
const HOST = process.env.HOST || "0.0.0.0";
const PUBLIC_URL = (process.env.BEGEMOT_PUBLIC_URL || `http://localhost:${PORT}`).replace(/\/+$/, "");

/**
 * Shared public API key — the same key for every deployment of this repo.
 * Anyone who clones it and starts `node server-http.mjs` gets a server that
 * already answers to this key, and every client config in the README works
 * unchanged against every such server. BEGEMOT_API_KEY overrides it when a
 * maintainer wants their own; setting it to "" disables the gate entirely.
 */
const SHARED_KEY = "9db6f52871e4c30a";
const API_KEY = "BEGEMOT_API_KEY" in process.env ? process.env.BEGEMOT_API_KEY || "" : SHARED_KEY;
const usingSharedKey = API_KEY !== "" && API_KEY === SHARED_KEY;
const AS_URL = process.env.BEGEMOT_OAUTH_AS_URL || "";
const ALLOWED_HOSTS = (process.env.BEGEMOT_ALLOWED_HOSTS || "").split(",").map((s) => s.trim()).filter(Boolean);

/* Remote: no file persistence, no shell. */
const core = createCore({ persist: false, allowShell: false });
const log = (...a) => console.error(`[begemot ${new Date().toISOString()}]`, ...a);

const app = createMcpExpressApp({
  host: HOST,
  ...(ALLOWED_HOSTS.length ? { allowedHosts: ALLOWED_HOSTS } : {})
});

/* ------------------------------------------------------------------ */
/* authorization                                                       */
/* ------------------------------------------------------------------ */
function extractKey(req) {
  const h = req.headers["authorization"] || "";
  if (h.toLowerCase().startsWith("bearer ")) return h.slice(7).trim();
  const x = req.headers["x-api-key"];
  return typeof x === "string" ? x.trim() : "";
}

function safeEqual(a, b) {
  const ba = Buffer.from(String(a || ""));
  const bb = Buffer.from(String(b || ""));
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

function requireAuth(req, res, next) {
  if (!API_KEY) return next();
  if (!safeEqual(extractKey(req), API_KEY)) {
    return res.status(401).json({ jsonrpc: "2.0", error: { code: -32001, message: "unauthorized" } });
  }
  next();
}

/* ------------------------------------------------------------------ */
/* MCP endpoint                                                        */
/* ------------------------------------------------------------------ */
async function handleMcp(req, res) {
  // Stateless: each request gets its own Server + transport, so nothing is
  // shared between clients. sessionIDGenerator undefined => no session id.
  const server = core.makeServer();
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on("close", () => {
    transport.close();
    server.close();
  });
  await server.connect(transport);
  await transport.handleRequest(req, res, req.body);
}

app.post("/mcp", requireAuth, (req, res) => {
  handleMcp(req, res).catch((e) => {
    log("mcp error:", e && e.stack ? e.stack : e);
    if (!res.headersSent) res.status(500).json({ error: "mcp error", detail: String(e) });
  });
});

// Stateless servers keep no standalone SSE stream open.
app.get("/mcp", requireAuth, (_req, res) => {
  res.status(405).json({ error: "method not allowed: use POST for Streamable HTTP" });
});
app.delete("/mcp", requireAuth, (_req, res) => {
  res.status(405).json({ error: "method not allowed" });
});

/* ------------------------------------------------------------------ */
/* diagnostics                                                         */
/* ------------------------------------------------------------------ */
app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    version: core.VERSION,
    transport: "streamable-http",
    mode: "stateless",
    shell_enabled: core.allowShell,
    auth: API_KEY ? "api-key" : "none",
    key_source: !API_KEY ? "open" : usingSharedKey ? "shared" : "custom",
    time: new Date().toISOString()
  });
});

// RFC 9728 resource metadata — only meaningful when a real authorization
// server fronts this endpoint. OpenCode discovers OAuth through it.
if (AS_URL) {
  app.get("/.well-known/oauth-protected-resource", (_req, res) => {
    res.json({
      resource: PUBLIC_URL,
      authorization_servers: [AS_URL],
      scopes_supported: ["mcp:read", "mcp:write"]
    });
  });
}

/* ------------------------------------------------------------------ */
/* boot                                                                */
/* ------------------------------------------------------------------ */
const listener = app.listen(PORT, HOST, () => {
  log(`Begemot MCP v${core.VERSION} — Streamable HTTP on http://${HOST}:${PORT}/mcp`);
  log(`   auth: ${!API_KEY ? "NONE (public)" : usingSharedKey ? `shared public key ${SHARED_KEY}` : "custom API key"}   shell: disabled   state: in-memory`);
  if (!API_KEY) log("   WARNING: BEGEMOT_API_KEY is set to an empty string — anyone with the URL can call this server.");
  else if (usingSharedKey) log(`   shared key: clients can use x-api-key: ${SHARED_KEY} (or Authorization: Bearer ${SHARED_KEY})`);
});

let shuttingDown = false;
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  log("shutting down");
  listener.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000).unref();
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
process.on("uncaughtException", (e) => log("uncaughtException:", e && e.stack ? e.stack : e));
process.on("unhandledRejection", (e) => log("unhandledRejection:", e));
