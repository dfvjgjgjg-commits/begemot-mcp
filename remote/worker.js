/**
 * Begemot MCP — Cloudflare Worker entrypoint (Streamable HTTP, stateless).
 *
 * Deploy with:
 *   npx wrangler deploy
 * Then point OpenCode at https://<worker>.workers.dev/mcp
 *
 * Set the API key as a secret:
 *   npx wrangler secret put BEGEMOT_API_KEY
 *
 * For GitHub OAuth instead of an API key, replace the fetch handler with
 * Cloudflare's OAuthProvider (workers-oauth-provider) wrapping the same
 * core.makeServer() — OpenCode discovers and completes that flow natively.
 */

import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { createCore } from "./core.mjs";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      const core = createCore({ persist: false, allowShell: false });
      return Response.json({
        ok: true,
        version: core.VERSION,
        transport: "streamable-http",
        mode: "stateless",
        shell_enabled: false,
        auth: env.BEGEMOT_API_KEY ? "api-key" : "none",
        time: new Date().toISOString()
      });
    }

    if (url.pathname !== "/mcp") {
      return new Response("not found", { status: 404 });
    }

    // Optional API-key gate. Remove this block if you use OAuthProvider.
    if (env.BEGEMOT_API_KEY) {
      const auth = request.headers.get("authorization") || "";
      const bearer = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : "";
      const got = bearer || request.headers.get("x-api-key") || "";
      if (got !== env.BEGEMOT_API_KEY) {
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
