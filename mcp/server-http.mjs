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
 *   BEGEMOT_PANEL_PUBLIC    "0" requires the API key for reads too (default:
 *                           reads - /, /status, /thoughts*, /thoughts.html,
 *                           /thoughts/stream - are public; writes stay keyed)
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
  if (typeof x === "string" && x.trim()) return x.trim();
  // EventSource (панель мыслей) не умеет задавать заголовки — ключ в query.
  const q = req.query && typeof req.query.key === "string" ? req.query.key.trim() : "";
  return q;
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

/* Reads are public by default: the point of the panel is that anyone can
 * watch how the model thinks. Writes (POST /thoughts) stay key-gated, so a
 * visitor can read but never inject. Set BEGEMOT_PANEL_PUBLIC=0 to require
 * the key for reads too. */
const PANEL_PUBLIC = process.env.BEGEMOT_PANEL_PUBLIC !== "0";
const readGuard = PANEL_PUBLIC ? (_req, _res, next) => next() : requireAuth;

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
/* thoughts feed (greenlight plugin streams model thinking here)        */
/* ------------------------------------------------------------------ */
const THOUGHTS_MAX = 1000;             // ring per session
const THOUGHTS_MAX_SESSIONS = 50;      // sessions kept in memory
const thoughts = new Map();            // sessionID -> array of records
const thoughtOrder = [];               // sessionIDs, oldest first (LRU)
const thoughtSse = new Set();          // live panel subscribers

function rememberThought(sessionID, rec) {
  let arr = thoughts.get(sessionID);
  if (!arr) {
    arr = [];
    thoughts.set(sessionID, arr);
    thoughtOrder.push(sessionID);
    while (thoughtOrder.length > THOUGHTS_MAX_SESSIONS) {
      thoughts.delete(thoughtOrder.shift());
    }
  }
  arr.push(rec);
  if (arr.length > THOUGHTS_MAX) arr.splice(0, arr.length - THOUGHTS_MAX);
  const payload = "data: " + JSON.stringify({ sessionID, ...rec }) + "\n\n";
  for (const res of thoughtSse) {
    try { res.write(payload); } catch { thoughtSse.delete(res); }
  }
}

// Ingest a single thought or an array of them. Body: { sessionID, messageID,
// kind, text, lang } or { sessionID, thoughts: [...] }. kind: thinking|text|
// refusal|reframe|system. Auth-gated like everything else here.
app.post("/thoughts", requireAuth, (req, res) => {
  const body = req.body || {};
  const sessionID = String(body.sessionID || "default").slice(0, 200);
  const list = Array.isArray(body.thoughts) ? body.thoughts : [body];
  const now = Date.now();
  const accepted = [];
  for (const t of list) {
    if (!t || typeof t !== "object") continue;
    const text = typeof t.text === "string" ? t.text.slice(0, 20000) : "";
    if (!text) continue;
    const rec = {
      ts: now,
      sessionID,
      messageID: String(t.messageID || "").slice(0, 200),
      kind: ["thinking", "text", "refusal", "reframe", "system"].includes(t.kind) ? t.kind : "thinking",
      lang: t.lang === "ru" ? "ru" : "en",
      text
    };
    rememberThought(sessionID, rec);
    accepted.push(rec);
  }
  res.json({ ok: true, stored: accepted.length });
});

// JSON view for a session (or all, newest last). Used by the panel bootstrap
// and by curl.
app.get("/thoughts", readGuard, (req, res) => {
  const sessionID = typeof req.query.session === "string" ? req.query.session : null;
  if (sessionID) {
    return res.json({ ok: true, sessionID, thoughts: thoughts.get(sessionID) || [] });
  }
  const all = [];
  for (const [sid, arr] of thoughts) all.push({ sessionID: sid, count: arr.length, last: arr[arr.length - 1] });
  res.json({ ok: true, sessions: all });
});

// Live stream: text/event-stream. Panel connects here; each stored thought is
// pushed as it arrives. Heartbeat every 20 s keeps proxies from dropping it.
app.get("/thoughts/stream", readGuard, (req, res) => {
  res.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
    connection: "keep-alive"
  });
  res.write("retry: 3000\n\n");
  const sid = typeof req.query.session === "string" ? req.query.session : null;
  const filter = sid
    ? (payload) => payload.sessionID === sid
    : () => true;
  const wrapped = {
    write(chunk) {
      const json = chunk.startsWith("data: ") ? chunk.slice(6).replace(/\n\n$/, "") : chunk;
      try {
        const obj = JSON.parse(json);
        if (!filter(obj)) return true;
      } catch { /* heartbeat or unknown frame - pass through */ }
      res.write(chunk);
      return true;
    }
  };
  thoughtSse.add(wrapped);
  const hb = setInterval(() => { try { res.write(": hb\n\n"); } catch { /* closed */ } }, 20000);
  req.on("close", () => { thoughtSse.delete(wrapped); clearInterval(hb); });
});

// Browser panel: shows every thought live, refusal/reframe highlighted.
app.get("/thoughts.html", readGuard, (_req, res) => {
  res.type("html").send(PANEL_HTML);
});

const PANEL_HTML = `<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>BEGEMOT - мысли модели</title>
<style>
  body{background:#0d0d0d;color:#c8c8c8;font:13px/1.45 Consolas,monospace;margin:0;padding:16px}
  h1{font-size:15px;color:#ff9d00;margin:0 0 10px}
  #bar{display:flex;gap:8px;margin-bottom:10px;flex-wrap:wrap}
  input,select,button{background:#161616;color:#c8c8c8;border:1px solid #333;padding:5px 8px;font:inherit}
  button{cursor:pointer}button:hover{border-color:#ff9d00}
  #log{border:1px solid #222;padding:8px;height:70vh;overflow-y:auto}
  .row{margin:0 0 6px;padding:4px 6px;border-left:3px solid #333}
  .thinking{border-color:#3a6ea5}.text{border-color:#555}
  .refusal{border-color:#a33;background:#1a0d0d;color:#ff8080}
  .reframe{border-color:#3a3;background:#0d1a0d;color:#80ff80}
  .system{border-color:#ff9d00;color:#ffce93}
  .meta{color:#666;font-size:11px}
  .dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:#333;margin-right:6px}
  .dot.on{background:#3a3}
  #count{color:#666;font-size:11px}
</style></head><body>
<h1>BEGEMOT - мысли модели (live)</h1>
<div id="bar">
  <span class="dot" id="dot"></span><span id="state">connecting...</span>
  <input id="filter" placeholder="фильтр по тексту" size="24">
  <select id="kind"><option value="">все виды</option><option>thinking</option><option>text</option><option>refusal</option><option>reframe</option><option>system</option></select>
  <button id="pause">пауза</button>
  <button id="clear">очистить</button>
  <span id="count"></span>
</div>
<div id="log"></div>
<script>
const key=new URLSearchParams(location.search).get("key")||"";
const logEl=document.getElementById("log"),dot=document.getElementById("dot"),state=document.getElementById("state"),countEl=document.getElementById("count");
let n=0,paused=false;const es=new EventSource("/thoughts/stream"+(key?"?key="+encodeURIComponent(key):""));
es.onopen=()=>{dot.classList.add("on");state.textContent="live"};
es.onerror=()=>{dot.classList.remove("on");state.textContent="reconnecting..."};
es.onmessage=e=>{if(paused)return;let m;try{m=JSON.parse(e.data)}catch{return}
  const f=document.getElementById("filter").value.toLowerCase(),k=document.getElementById("kind").value;
  if(f&&!m.text.toLowerCase().includes(f))return;if(k&&m.kind!==k)return;
  const d=document.createElement("div");d.className="row "+m.kind;
  const t=new Date(m.ts).toLocaleTimeString();
  d.innerHTML='<div class="meta">'+t+" ["+m.kind+"] "+(m.sessionID||"")+(m.lang==="ru"?" ru":"")+'</div><div></div>';
  d.lastChild.textContent=m.text;logEl.appendChild(d);logEl.scrollTop=logEl.scrollHeight;
  if(++n>2000){logEl.removeChild(logEl.firstChild);n--}countEl.textContent=n+" записей"};
document.getElementById("pause").onclick=e=>{paused=!paused;e.target.textContent=paused?"продолжить":"пауза"};
document.getElementById("clear").onclick=()=>{logEl.innerHTML="";n=0;countEl.textContent=""};
</script></body></html>`;

/* ------------------------------------------------------------------ */
/* root: server overview + link to the live panel                       */
/* ------------------------------------------------------------------ */
function overview() {
  let total = 0;
  let last = null;
  for (const arr of thoughts.values()) {
    total += arr.length;
    const rec = arr[arr.length - 1];
    if (rec && (!last || rec.ts > last.ts)) last = rec;
  }
  return {
    ok: true,
    name: "Begemot MCP",
    version: core.VERSION,
    auth: API_KEY ? "api-key" : "none",
    panel_public: PANEL_PUBLIC,
    thoughts: { sessions: thoughts.size, records: total, last },
    uptime_s: Math.round(process.uptime()),
    time: new Date().toISOString()
  };
}

app.get("/status", readGuard, (_req, res) => res.json(overview()));

app.get("/", readGuard, (_req, res) => res.type("html").send(ROOT_HTML));

const ROOT_HTML = `<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Begemot MCP - статус сервера</title>
<style>
  body{background:#0d0d0d;color:#c8c8c8;font:14px/1.5 Consolas,monospace;margin:0;padding:24px;max-width:840px}
  h1{color:#ff9d00;font-size:20px;margin:0 0 4px}
  .sub{color:#666;margin-bottom:20px}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:10px;margin-bottom:20px}
  .tile{background:#141414;border:1px solid #262626;border-radius:6px;padding:12px}
  .tile .k{color:#666;font-size:11px;text-transform:uppercase;letter-spacing:.08em}
  .tile .v{font-size:22px;color:#f0f0f0;margin-top:4px}
  .tile .v.on{color:#3ad07a}
  a.btn{display:inline-block;background:#ff9d00;color:#111;padding:10px 18px;border-radius:6px;text-decoration:none;font-weight:bold;margin-right:10px}
  a.btn.alt{background:#1f1f1f;color:#ff9d00;border:1px solid #ff9d00}
  #last{background:#141414;border:1px solid #262626;border-radius:6px;padding:12px;margin-top:14px;min-height:60px}
  #last .who{color:#666;font-size:11px;margin-bottom:6px}
  footer{color:#555;margin-top:26px;font-size:12px}
  .dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:#3ad07a;margin-right:6px}
</style></head><body>
<h1>BEGEMOT MCP</h1>
<div class="sub">сервер жив - мысли модели видны вживую</div>
<div class="grid">
  <div class="tile"><div class="k">версия</div><div class="v" id="ver">-</div></div>
  <div class="tile"><div class="k">uptime</div><div class="v" id="up">-</div></div>
  <div class="tile"><div class="k">сессий</div><div class="v" id="sess">-</div></div>
  <div class="tile"><div class="k">записей мыслей</div><div class="v" id="rec">-</div></div>
</div>
<a class="btn" href="/thoughts.html">ПАНЕЛЬ МЫСЛЕЙ - как думает модель</a>
<a class="btn alt" href="/status">status.json</a>
<a class="btn alt" href="/health">health</a>
<div id="last"><div class="who"><span class="dot"></span>последняя мысль</div><div id="lastText">ожидание...</div></div>
<footer>запись на сервер идёт от плагина greenlight; чтение открыто, запись - по ключу API</footer>
<script>
async function tick(){
  try{
    const s=await (await fetch("/status")).json();
    ver.textContent=s.version;
    up.textContent=Math.floor(s.uptime_s/60)+"м "+(s.uptime_s%60)+"с";
    sess.textContent=s.thoughts.sessions;
    rec.textContent=s.thoughts.records;
    if(s.thoughts.last){
      const l=s.thoughts.last;
      lastText.textContent="["+(l.kind||"?")+"] "+(l.text||"").slice(0,300);
    }
  }catch(e){}
}
tick();setInterval(tick,3000);
</script></body></html>`;

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
