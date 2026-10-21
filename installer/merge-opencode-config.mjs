#!/usr/bin/env node
/**
 * merge-opencode-config.mjs - surgical JSONC merge for the OpenCode config.
 *
 * Why not "JSON.parse -> mutate -> JSON.stringify": that rewrite deletes every
 * comment in the user's config and re-formats the whole file. Users notice,
 * users stop trusting the installer, and some setups break outright.
 *
 * So the file is edited as TEXT. Every byte we do not touch stays exactly as
 * it was: comments, key order, formatting, trailing commas.
 *
 * Two other facts drive the design (both verified against OpenCode v2.1.2):
 *   - `mcp.servers` (current schema) and the flat `mcp.<name>` (legacy) are
 *     BOTH read, so the shape has to match what the target config already
 *     uses, otherwise the file ends up with two copies of the same server and
 *     the model sees every tool twice.
 *   - OpenCode merges `opencode.json` and `opencode.jsonc` as a union, so the
 *     entry has to be written into every config file that exists - otherwise a
 *     second file with its own `mcp` block can shadow ours.
 *
 * usage:
 *   node merge-opencode-config.mjs <configDir> <promptPath> <mcpDir> <nodeExe> <pluginPath> [shape]
 *
 * shape: auto (default) | nested | flat
 *   auto   - keep the shape each config file already uses; use `nested` for
 *            files that have no MCP block yet.
 *   nested - mcp.servers.<name>      (current OpenCode schema)
 *   flat   - mcp.<name>              (legacy OpenCode schema)
 */

import { existsSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";

const NAME = "begemot-traffic-light";
const CONFIG_FILES = ["opencode.jsonc", "opencode.json"];

/* ------------------------------------------------------------------ scanner
   Exported so that unmerge-opencode-config.mjs (the uninstall side) walks the
   same scanner - two different parsers over one file is how you end up with
   two different opinions about where a value ends. */

export function skipString(s, i) {
  let j = i + 1;
  while (j < s.length) {
    const c = s[j];
    if (c === "\\") { j += 2; continue; }
    if (c === '"') return j + 1;
    j++;
  }
  throw new Error("unterminated string at offset " + i);
}

export function skipTrivia(s, i) {
  for (;;) {
    while (i < s.length && /\s/.test(s[i])) i++;
    if (s[i] === "/" && s[i + 1] === "/") { while (i < s.length && s[i] !== "\n") i++; continue; }
    if (s[i] === "/" && s[i + 1] === "*") {
      const e = s.indexOf("*/", i + 2);
      i = e === -1 ? s.length : e + 2;
      continue;
    }
    return i;
  }
}

export function skipContainer(s, i) {
  const open = s[i];
  const close = open === "{" ? "}" : "]";
  let depth = 0;
  let j = i;
  while (j < s.length) {
    const c = s[j];
    if (c === '"') { j = skipString(s, j); continue; }
    if (c === "/" && s[j + 1] === "/") { while (j < s.length && s[j] !== "\n") j++; continue; }
    if (c === "/" && s[j + 1] === "*") { const e = s.indexOf("*/", j + 2); j = e === -1 ? s.length : e + 2; continue; }
    if (c === open) { depth++; j++; continue; }
    if (c === close) { depth--; j++; if (depth === 0) return j; continue; }
    j++;
  }
  throw new Error("unterminated container at offset " + i);
}

export function skipValue(s, i) {
  const c = s[i];
  if (c === '"') return skipString(s, i);
  if (c === "{" || c === "[") return skipContainer(s, i);
  let j = i;
  while (j < s.length && !/[\s,}\]]/.test(s[j])) j++;
  return j;
}

export function scanObject(s, open) {
  const end = skipContainer(s, open);
  const props = [];
  let i = open + 1;
  while (i < end - 1) {
    i = skipTrivia(s, i);
    if (i >= end - 1) break;
    if (s[i] === ",") { i++; continue; }
    if (s[i] !== '"') break;
    const keyEnd = skipString(s, i);
    let key;
    try { key = JSON.parse(s.slice(i, keyEnd)); } catch { break; }
    let j = skipTrivia(s, keyEnd);
    if (s[j] !== ":") break;
    j = skipTrivia(s, j + 1);
    const valueStart = j;
    const valueEnd = skipValue(s, j);
    props.push({ key, keyStart: i, keyEnd, valueStart, valueEnd });
    i = valueEnd;
  }
  return { props, end };
}

export function scanArray(s, open) {
  const end = skipContainer(s, open);
  const items = [];
  let i = open + 1;
  while (i < end - 1) {
    i = skipTrivia(s, i);
    if (i >= end - 1) break;
    if (s[i] === ",") { i++; continue; }
    const valueStart = i;
    const valueEnd = skipValue(s, i);
    if (valueEnd <= valueStart) break;
    items.push({ valueStart, valueEnd });
    i = valueEnd;
  }
  return { items, end };
}

/* ------------------------------------------------------------------ helpers */

export function lineIndent(s, pos) {
  const ls = s.lastIndexOf("\n", pos) + 1;
  let i = ls;
  while (i < s.length && (s[i] === " " || s[i] === "\t")) i++;
  return s.slice(ls, i);
}

function pretty(value, indent) {
  const pad = " ".repeat(Math.max(0, indent));
  return JSON.stringify(value, null, 2)
    .split("\n")
    .map((l, i) => (i === 0 ? l : pad + l))
    .join("\n");
}

export function applyOps(text, ops) {
  const groups = new Map();
  for (const op of ops) {
    const key = op.start + ":" + op.end;
    if (!groups.has(key)) groups.set(key, { start: op.start, end: op.end, parts: [] });
    groups.get(key).parts.push(op.text);
  }
  let out = text;
  for (const g of [...groups.values()].sort((a, b) => b.start - a.start)) {
    // Several keys can land on the same spot (a freshly created object, or a
    // file missing several top-level keys at once). They must come out
    // comma-separated or the file stops being valid JSON, but the comma belongs
    // right after the value - not after the indentation that follows it.
    // The last part keeps whatever terminator it already carries: a trailing
    // comma in it means the original object had members after our insertion.
    // Removal ops arrive with an empty text and must contribute nothing.
    const parts = g.parts
      .map((t) => t ?? "")
      .filter((t) => t !== "");
    let merged = "";
    for (let i = 0; i < parts.length; i++) {
      const lead = (parts[i].match(/^\s*/) || [""])[0];
      const body = parts[i].slice(lead.length).replace(/\s+$/, "");
      const isLast = i === parts.length - 1;
      const terminator = isLast ? "" : (/,$/.test(body) ? "" : ",");
      merged += lead + body + terminator;
    }
    out = out.slice(0, g.start) + merged + out.slice(g.end);
  }
  return out;
}

/* set a member of the object literal that starts at objOpen */
function setMember(s, objOpen, key, valueJson, keyIndent) {
  const { props } = scanObject(s, objOpen);
  const hit = props.find((p) => p.key === key);
  if (hit) return [{ start: hit.valueStart, end: hit.valueEnd, text: valueJson }];
  const ind = keyIndent ?? lineIndent(s, objOpen + 1);
  if (!props.length) {
    return [{ start: objOpen + 1, end: objOpen + 1, text: "\n" + ind + "  " + JSON.stringify(key) + ": " + valueJson + "\n" + ind }];
  }
  const first = lineIndent(s, props[0].keyStart);
  return [{ start: objOpen + 1, end: objOpen + 1, text: "\n" + first + JSON.stringify(key) + ": " + valueJson + ",\n" + first }];
}

/* append an item to the array literal that starts at arrOpen (null = already there) */
function appendItem(s, arrOpen, valueJson) {
  const { items, end } = scanArray(s, arrOpen);
  for (const it of items) {
    if (s.slice(it.valueStart, it.valueEnd) === valueJson) return null;
  }
  if (!items.length) {
    const ind = lineIndent(s, arrOpen);
    return [{ start: arrOpen + 1, end: arrOpen + 1, text: "\n" + ind + "  " + valueJson + "\n" + ind }];
  }
  const last = items[items.length - 1];
  const ind = lineIndent(s, last.valueStart);
  const tail = s.slice(last.valueEnd, end - 1);
  const commaAt = tail.indexOf(",");
  if (commaAt !== -1) {
    // the array already ends with a comma (trailing comma style) - insert after it
    const pos = last.valueEnd + commaAt + 1;
    return [{ start: pos, end: pos, text: "\n" + ind + "  " + valueJson }];
  }
  return [{ start: last.valueEnd, end: last.valueEnd, text: ",\n" + ind + "  " + valueJson }];
}

/* ------------------------------------------------------------------- merge */

function mergeFile(path, opts) {
  const { promptPath, pluginPath, serverCfg, shape } = opts;
  let text = existsSync(path) ? readFileSync(path, "utf8").replace(/^\uFEFF/, "") : "";
  const created = !existsSync(path);
  if (!text.trim()) text = "{\n}\n";

  const objOpen = skipTrivia(text, 0);
  if (text[objOpen] !== "{") throw new Error(path + ": root is not a JSON object");

  const top = scanObject(text, objOpen);
  const find = (k) => top.props.find((p) => p.key === k);
  const ops = [];
  const notes = [];

  /* ---- mcp ---- */
  const mcpProp = find("mcp");
  let usedShape = shape === "auto" ? "nested" : shape;

  if (mcpProp && text[mcpProp.valueStart] === "{") {
    const inner = scanObject(text, mcpProp.valueStart);
    const serversProp = inner.props.find((p) => p.key === "servers");
    const flatEntries = inner.props.filter((p) => p.key !== "servers" && p.key !== "timeout");
    const mcpIndent = lineIndent(text, mcpProp.keyStart);

    if (serversProp && text[serversProp.valueStart] === "{") {
      usedShape = "nested";
      const srvIndent = lineIndent(text, serversProp.keyStart);
      ops.push(...setMember(text, serversProp.valueStart, NAME, pretty(serverCfg, srvIndent.length + 2), srvIndent + "  "));
    } else if (flatEntries.length) {
      usedShape = "flat";
      ops.push(...setMember(text, mcpProp.valueStart, NAME, pretty(serverCfg, mcpIndent.length + 2), mcpIndent + "  "));
    } else if (serversProp) {
      usedShape = "nested";
      const srvIndent = lineIndent(text, serversProp.keyStart);
      ops.push({ start: serversProp.valueStart, end: serversProp.valueEnd, text: pretty({ [NAME]: serverCfg }, srvIndent.length + 2) });
    } else if (usedShape === "flat") {
      ops.push(...setMember(text, mcpProp.valueStart, NAME, pretty(serverCfg, mcpIndent.length + 2), mcpIndent + "  "));
    } else {
      const srvIndent = mcpIndent + "  ";
      ops.push(...setMember(text, mcpProp.valueStart, "servers", pretty({ [NAME]: serverCfg }, srvIndent.length + 2), srvIndent));
    }
  } else if (mcpProp) {
    const mcpIndent = lineIndent(text, mcpProp.keyStart);
    const value = usedShape === "flat" ? { [NAME]: serverCfg } : { servers: { [NAME]: serverCfg } };
    ops.push({ start: mcpProp.valueStart, end: mcpProp.valueEnd, text: pretty(value, mcpIndent.length + 2) });
  } else {
    const value = usedShape === "flat" ? { [NAME]: serverCfg } : { servers: { [NAME]: serverCfg } };
    const topIndent = lineIndent(text, objOpen + 1);
    ops.push(...setMember(text, objOpen, "mcp", pretty(value, topIndent.length + 2), topIndent + "  "));
  }

  /* ---- instructions / plugins (arrays) ---- */
  for (const [key, value] of [["instructions", promptPath], ["plugins", pluginPath]]) {
    if (!value) continue;
    const prop = find(key);
    if (!prop) {
      const topIndent = lineIndent(text, objOpen + 1);
      ops.push(...setMember(text, objOpen, key, pretty([value], topIndent.length + 2), topIndent + "  "));
      continue;
    }
    if (text[prop.valueStart] !== "[") {
      notes.push(key + " exists but is not an array - left untouched");
      continue;
    }
    const op = appendItem(text, prop.valueStart, JSON.stringify(value));
    if (op) ops.push(...op);
  }

  const out = applyOps(text, ops);
  if (out !== text || created) {
    writeFileSync(path, out.endsWith("\n") ? out : out + "\n", "utf8");
  }
  return { path, created, shape: usedShape, changed: out !== text || created, notes };
}

/* ------------------------------------------------------------------- main
   Guarded: unmerge-opencode-config.mjs imports the scanner from here, and an
   import must not run the CLI. */

const isMain = !!process.argv[1] &&
  process.argv[1].replace(/\\/g, "/").split("/").pop() === "merge-opencode-config.mjs";

if (isMain) {
  const [configDir, promptPath, mcpDir, nodeExe, pluginPath, shapeArg] = process.argv.slice(2);
  if (!configDir || !promptPath || !mcpDir || !nodeExe) {
    console.error("usage: merge-opencode-config.mjs <configDir> <promptPath> <mcpDir> <nodeExe> <pluginPath> [shape]");
    process.exit(64);
  }
  const shape = shapeArg || "auto";

  const serverCfg = {
    type: "local",
    command: [nodeExe, join(mcpDir, "server.js")],
    codemode: false,
  };

  const existing = CONFIG_FILES.map((f) => join(configDir, f)).filter((p) => existsSync(p));
  const targets = existing.length ? existing : [join(configDir, "opencode.jsonc")];

  let failed = 0;
  for (const t of targets) {
    try {
      const res = mergeFile(t, { promptPath, pluginPath, serverCfg, shape });
      console.log(
        "merged " + (res.created ? "(created)" : res.changed ? "(updated)" : "(already ok)") +
        " shape=" + res.shape + " -> " + res.path
      );
      for (const n of res.notes) console.log("  note: " + n);
    } catch (e) {
      failed++;
      console.error("FAILED " + t + ": " + e.message);
    }
  }
  process.exit(failed ? 1 : 0);
}
