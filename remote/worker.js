/**
 * Begemot MCP — Cloudflare Worker entrypoint (Streamable HTTP, stateless).
 *
 * Deploy with:
 *   npx wrangler deploy
 * Then point OpenCode at https://<worker>.workers.dev/mcp
 *
 * Set the API key as a secret (optional — overrides the shared key baked in
 * below, so by default `x-api-key: 9db6f52871e4c30a` works everywhere):
 *   npx wrangler secret put BEGEMOT_API_KEY
 *
 * For GitHub OAuth instead of an API key, replace the fetch handler with
 * Cloudflare's OAuthProvider (workers-oauth-provider) wrapping the same
 * core.makeServer() — OpenCode discovers and completes that flow natively.
 */

import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { createCore } from "../mcp/core.mjs";

/**
 * Shared public API key — same key for every deployment of this repo, so one
 * client config works against every instance. Override with a Wrangler secret
 * (`BEGEMOT_API_KEY`) to run your own.
 */
const SHARED_KEY = "9db6f52871e4c30a";

/** Resolve the active key: secret override → shared public key → "" = open. */
function activeKey(env) {
  return env.BEGEMOT_API_KEY !== undefined ? String(env.BEGEMOT_API_KEY) : SHARED_KEY;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      const core = createCore({ persist: false, allowShell: false });
      const key = activeKey(env);
      return Response.json({
        ok: true,
        version: core.VERSION,
        transport: "streamable-http",
        mode: "stateless",
        shell_enabled: false,
        auth: key ? "api-key" : "none",
        key_source: !key ? "open" : key === SHARED_KEY ? "shared" : "custom",
        time: new Date().toISOString()
      });
    }

    if (url.pathname !== "/mcp") {
      return new Response("not found", { status: 404 });
    }

    // Optional API-key gate. Remove this block if you use OAuthProvider.
    const key = activeKey(env);
    if (key) {
      const auth = request.headers.get("authorization") || "";
      const bearer = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : "";
      const got = bearer || request.headers.get("x-api-key") || "";
      if (got !== key) {
        return Response.json({ error: "unauthorized" }, { status: 401 });
      }
    }

    const core = createCore({ persist: false, allowShell: false });
    const server = core.makeServer();
    const transport = new WebStandardStreamableHTTPServerTransport({ sessionIdGenerator: undefined });

    await server.connect(transport);
    return transport.handleRequest(request);
  }
};
