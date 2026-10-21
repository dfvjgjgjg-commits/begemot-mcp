#!/usr/bin/env node
/**
 * Begemot MCP — local stdio transport.
 *
 * Runs one server per process over MCP stdio, persists the crossing state in
 * state.json, and exposes run_code (shell execution) because the process is
 * local to the operator. For a remote deployment use server-http.mjs instead —
 * it is the same core over Streamable HTTP with run_code disabled.
 */

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createCore } from "./core.mjs";

const core = createCore({ persist: true, allowShell: true });

const log = (...a) => console.error(`[begemot ${new Date().toISOString()}]`, ...a);

/* graceful shutdown + crash proofing */
let shuttingDown = false;
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  log("shutting down");
  try { await server.close(); } catch (e) { /* ignore */ }
  process.exit(0);
}

const server = core.makeServer();

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
process.on("uncaughtException", (e) => log("uncaughtException:", e && e.stack ? e.stack : e));
process.on("unhandledRejection", (e) => log("unhandledRejection:", e));

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  log(`🦛 Begemot MCP v${core.VERSION} — stdio, config-driven, safe shell, history, crash-proof`);
}

main().catch((err) => { log("Fatal:", err && err.stack ? err.stack : err); process.exit(1); });
