#!/usr/bin/env node
/**
 * unmerge-opencode-config.mjs - surgical removal of the Begemot entries.
 *
 * The exact inverse of merge-opencode-config.mjs, built on the same scanner
 * (imported from there), because removal is where text editing gets dangerous:
 * a wrong span and the user's config stops parsing. The same rules apply -
 * every byte we do not touch stays exactly as it was, comments included.
 *
 * Removes, from EVERY config file in the directory:
 *   - mcp.servers["begemot-traffic-light"]  or  mcp["begemot-traffic-light"]
 *   - the `servers` block / the whole `mcp` key when it would be left empty
 *   - our prompt path from `instructions`
 *   - our plugin path from `plugins`
 *
 * Everything the user owns stays: their servers, their rules, their plugins.
 * Idempotent - running it on a clean config changes nothing and exits 0.
 *
 * usage: node unmerge-opencode-config.mjs <configDir> <promptPath> [pluginPath]
 */

import { existsSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import {
  scanObject, scanArray, lineIndent, skipTrivia, applyOps,
} from "./merge-opencode-config.mjs";

const NAME = "begemot-traffic-light";
const CONFIG_FILES = ["opencode.jsonc", "opencode.json"];

/* ------------------------------------------------------------- primitives */

/** Start of the member's own line when only spaces/tabs separate it from the
 *  key - removing from there keeps the next member's indentation intact
 *  instead of stacking two indents. */
function lineStartIfAligned(s, keyStart) {
  const ls = s.lastIndexOf("\n", keyStart) + 1;
  return /^[ \t]*$/.test(s.slice(ls, keyStart)) ? ls : keyStart;
}

/**
 * Remove a member from the object literal starting at objOpen.
 * Consumes exactly one comma (the one before the next member, or the one before
 * this one if it is last) and the line break after it, so no blank line is left.
 */
function removeMember(s, objOpen, key) {
  const { props, end } = scanObject(s, objOpen);
  const idx = props.findIndex((p) => p.key === key);
  if (idx === -1) return null;
  const p = props[idx];

  if (idx < props.length - 1) {
    const next = props[idx + 1];
    const gap = s.slice(p.valueEnd, next.keyStart);
    const comma = gap.indexOf(",");
    if (comma === -1) return { start: p.keyStart, end: p.valueEnd }; // odd but safe
    let e = p.valueEnd + comma + 1;
    let j = e;
    while (j < next.keyStart && (s[j] === " " || s[j] === "\t")) j++;
    if (s[j] === "\n") e = j + 1;
    return { start: lineStartIfAligned(s, p.keyStart), end: e };
  }

  const head = s.slice(objOpen + 1, p.keyStart);
  const comma = head.lastIndexOf(",");
  if (comma !== -1) return { start: objOpen + 1 + comma, end: p.valueEnd };

  // the only member: swallow the whitespace around it, leaving `{}` / `[]`
  let start = p.keyStart;
  let k = start - 1;
  while (k > objOpen && /\s/.test(s[k])) k--;
  start = k + 1;
  let e = p.valueEnd;
  while (e < end - 1 && /\s/.test(s[e])) e++;
  return { start, end: e };
}

/** Remove an array item whose raw JSON equals valueJson (null when absent). */
function removeArrayItem(s, arrOpen, valueJson) {
  const { items, end } = scanArray(s, arrOpen);
  const idx = items.findIndex((it) => s.slice(it.valueStart, it.valueEnd) === valueJson);
  if (idx === -1) return null;
  const it = items[idx];

  if (idx < items.length - 1) {
    const next = items[idx + 1];
    const gap = s.slice(it.valueEnd, next.valueStart);
    const comma = gap.indexOf(",");
    if (comma === -1) return { start: it.valueStart, end: it.valueEnd };
    let e = it.valueEnd + comma + 1;
    let j = e;
    while (j < next.valueStart && (s[j] === " " || s[j] === "\t")) j++;
    if (s[j] === "\n") e = j + 1;
    return { start: lineStartIfAligned(s, it.valueStart), end: e };
  }

  const head = s.slice(arrOpen + 1, it.valueStart);
  const comma = head.lastIndexOf(",");
  if (comma !== -1) return { start: arrOpen + 1 + comma, end: it.valueEnd };

  let start = it.valueStart;
  let k = start - 1;
  while (k > arrOpen && /\s/.test(s[k])) k--;
  start = k + 1;
  let e = it.valueEnd;
  while (e < end - 1 && /\s/.test(s[e])) e++;
  return { start, end: e };
}

/* ----------------------------------------------------------------- unmerge */

function unmergeFile(path, opts) {
  const { promptPath, pluginPath } = opts;
  if (!existsSync(path)) return { path, removed: [], changed: false };

  const text = readFileSync(path, "utf8");
  const topOpen = skipTrivia(text, 0);
  if (text[topOpen] !== "{") return { path, removed: ["(root is not an object)"], changed: false };

  const top = scanObject(text, topOpen);
  const ops = [];
  const removed = [];

  /* ---- mcp ---- */
  const mcpProp = top.props.find((p) => p.key === "mcp");
  if (mcpProp && text[mcpProp.valueStart] === "{") {
    const inner = scanObject(text, mcpProp.valueStart);
    const serversProp = inner.props.find((p) => p.key === "servers");
    const flatHasOurs = inner.props.some((p) => p.key === NAME);
    let nestedHasOurs = false;
    let serversOther = 0;

    if (serversProp && text[serversProp.valueStart] === "{") {
      const sinner = scanObject(text, serversProp.valueStart);
      nestedHasOurs = sinner.props.some((p) => p.key === NAME);
      serversOther = sinner.props.filter((p) => p.key !== NAME).length;
    }

    const mcpOthers = inner.props.filter((p) => {
      if (p.key === NAME) return false;
      if (p.key === "servers") {
        return serversProp ? serversOther > 0 : false;
      }
      return true; // timeout, or anything else the user added
    }).length;

    if (nestedHasOurs || flatHasOurs) {
      if (mcpOthers === 0) {
        // nothing left but our entry -> drop the whole mcp key
        const op = removeMember(text, topOpen, "mcp");
        if (op) { ops.push(op); removed.push("mcp"); }
      } else if (nestedHasOurs && flatHasOurs) {
        // both shapes carry our name: take it from each, keeping the rest
        const opS = removeMember(text, serversProp.valueStart, NAME);
        if (opS) { ops.push(opS); removed.push("mcp.servers." + NAME); }
        const opF = removeMember(text, mcpProp.valueStart, NAME);
        if (opF) { ops.push(opF); removed.push("mcp." + NAME); }
      } else if (nestedHasOurs) {
        if (serversOther === 0) {
          const op = removeMember(text, mcpProp.valueStart, "servers");
          if (op) { ops.push(op); removed.push("mcp.servers"); }
        } else {
          const op = removeMember(text, serversProp.valueStart, NAME);
          if (op) { ops.push(op); removed.push("mcp.servers." + NAME); }
        }
      } else {
        const op = removeMember(text, mcpProp.valueStart, NAME);
        if (op) { ops.push(op); removed.push("mcp." + NAME); }
      }
    }
  }

  /* ---- instructions / plugins ---- */
  for (const [key, value] of [["instructions", promptPath], ["plugins", pluginPath]]) {
    if (!value) continue;
    const prop = top.props.find((p) => p.key === key);
    if (!prop || text[prop.valueStart] !== "[") continue;
    const op = removeArrayItem(text, prop.valueStart, JSON.stringify(value));
    if (op) { ops.push(op); removed.push(key); }
  }

  if (!ops.length) return { path, removed, changed: false };

  const out = applyOps(text, ops);
  if (out !== text) {
    writeFileSync(path, out.endsWith("\n") ? out : out + "\n", "utf8");
    return { path, removed, changed: true };
  }
  return { path, removed, changed: false };
}

/* -------------------------------------------------------------------- main */

const isMain = !!process.argv[1] &&
  process.argv[1].replace(/\\/g, "/").split("/").pop() === "unmerge-opencode-config.mjs";

if (isMain) {
  const [configDir, promptPath, pluginPath] = process.argv.slice(2);
  if (!configDir || !promptPath) {
    console.error("usage: unmerge-opencode-config.mjs <configDir> <promptPath> [pluginPath]");
    process.exit(64);
  }

  const targets = CONFIG_FILES
    .map((f) => join(configDir, f))
    .filter((p) => existsSync(p));

  if (!targets.length) {
    console.log("no opencode config to clean in " + configDir);
    process.exit(0);
  }

  let failed = 0;
  for (const t of targets) {
    try {
      const res = unmergeFile(t, { promptPath, pluginPath });
      console.log(
        (res.changed ? "removed " : "clean (nothing to remove)") + " -> " + res.path +
        (res.removed.length ? "  [" + res.removed.join(", ") + "]" : "")
      );
    } catch (e) {
      failed++;
      console.error("FAILED " + t + ": " + e.message);
    }
  }
  process.exit(failed ? 1 : 0);
}

export { unmergeFile, removeMember, removeArrayItem };
