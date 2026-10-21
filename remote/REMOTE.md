# Begemot MCP в интернете (OpenCode V2, remote server)

Как отдавать этот MCP по сети и подключать к нему OpenCode как к **remote** серверу.

## 1. Что теперь в проекте

| Файл | Назначение |
|---|---|
| `core.mjs` | всё ядро: конфиг, reasoning protocol, tools/prompts/resources, обработчики |
| `server.js` | локальный транспорт **stdio** (как было) |
| `server-http.mjs` | **Streamable HTTP** — Node/Express, удалённый запуск |
| `worker.js` | **Cloudflare Worker** — stateless, бесплатный хостинг |
| `Dockerfile` | контейнер для VPS / Fly / Render / Railway |
| `wrangler.jsonc` | конфиг Cloudflare Workers |

Ядро одно. Транспорт выбирается точкой входа, поэтому логика не дублируется.

## 2. Как OpenCode V2 подключается к удалённому MCP

OpenCode различает `type: "local"` (stdio, процесс на машине) и `type: "remote"`
(Streamable HTTP, абсолютный URL). Удалённый сервер по умолчанию использует OAuth;
если авторизация сделана через заголовок с ключом — `oauth: false`.

```sh
opencode mcp add begemot --global --url https://begemot.example.com/mcp
opencode mcp list
```

Или в `opencode.jsonc`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "begemot": {
        "type": "remote",
        "url": "https://begemot.example.com/mcp",
        "oauth": false,
        "headers": { "x-api-key": "{env:BEGEMOT_API_KEY}" }
      }
    }
  }
}
```

Ключевое: **OpenCode забирает `instructions` из ответа `initialize` и кладёт их в
системный промпт** — то есть reasoning protocol доезжает до модели и по HTTP,
без локального плагина. Плюс инструменты и промпты (`/begemot:begemot_execute`).

## 3. Вариант A — Node/Express + API key

Самый быстрый путь: любой VPS, Fly.io, Render, Railway.

```sh
git clone https://github.com/dfvjgjgjg-commits/begemot-mcp
cd begemot-mcp
npm install
BEGEMOT_API_KEY=<случайный_ключ> PORT=8788 node server-http.mjs
```

Или контейнером:

```sh
docker build -t begemot-mcp .
docker run -d -p 8788:8788 -e BEGEMOT_API_KEY=<ключ> begemot-mcp
```

Переменные:

| Переменная | Зачем |
|---|---|
| `PORT` | порт, по умолчанию 8788 |
| `HOST` | `0.0.0.0` за прокси, `127.0.0.1` если прокси на той же машине |
| `BEGEMOT_API_KEY` | если задан — каждый `/mcp` требует `Authorization: Bearer <ключ>` или `x-api-key: <ключ>` |
| `BEGEMOT_ALLOWED_HOSTS` | запятая-разделённый список Host при бинде на `0.0.0.0` (защита от DNS rebinding) |
| `BEGEMOT_PUBLIC_URL` | публичный origin, для OAuth-метаданных |
| `BEGEMOT_OAUTH_AS_URL` | если задан — публикует RFC 9728 `/.well-known/oauth-protected-resource` |

Проверка:

```sh
curl https://begemot.example.com/health
# {"ok":true,"version":"6.3.0","transport":"streamable-http","mode":"stateless","shell_enabled":false,"auth":"api-key"}
```

## 4. Вариант B — Cloudflare Workers (рекомендуется для раздачи людям)

Stateless, бесплатный тир, свой домен, нет сервера.

```sh
npx wrangler deploy
npx wrangler secret put BEGEMOT_API_KEY
```

URL будет `https://<worker>.<account>.workers.dev/mcp` → его и указываешь в
OpenCode как `type: "remote"`.

### GitHub OAuth вместо API key

OpenCode умеет CIMD и DCR, поэтому для раздачи другим людям удобнее OAuth: у
пользователя спрашивает вход через GitHub, токен хранит сам OpenCode. В Cloudflare
это `OAuthProvider` из `workers-oauth-provider`:

```js
import { OAuthProvider } from "workers-oauth-provider";

export default new OAuthProvider({
  apiRoute: "/mcp",
  apiHandler: BegemotMCP.serve("/mcp"),   // stateless handler над core.makeServer()
  defaultHandler: GitHubHandler,
  authorizeEndpoint: "/authorize",
  tokenEndpoint: "/token",
  clientRegistrationEndpoint: "/register",
});
```

Секреты: `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `COOKIE_ENCRYPTION_KEY`, плюс
KV-неймспейс `OAUTH_KV`. Тогда в OpenCode просто `--url` без `oauth: false`.

## 5. Что обязательно учесть

1. **`run_code` в удалённой сборке отсутствует.** Он зарегистрирован только в
   `server.js` (stdio). `createCore({ allowShell: false })` его не добавляет, а
   вызов возвращает ошибку. Shell-эндпоинт в интернете — это RCE.
2. **Состояние в памяти.** Удалённый сервер stateless: счётчик шагов живёт в
   Map и обнуляется с процессом. Для протокольной работы это не важно; если нужна
   сквозная история — подключи KV/Postgres и передавай ключ из
   `_meta["ai.opencode/sessionID"]` (OpenCode его присылает).
3. **Авторизация обязательна.** Публичный URL без ключа = открытый MCP.
4. **HTTPS обязателен.** OpenCode требует абсолютный URL; за прокси — терминируй TLS.
5. **Ключ — в переменные окружения**, не в конфиг и не в репозиторий.

## 6. Проверка после деплоя

```sh
# 1. health
curl https://begemot.example.com/health

# 2. без ключа — 401
curl -o /dev/null -w "%{http_code}\n" -X POST https://begemot.example.com/mcp \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}'

# 3. с ключом — 200 и в ответе instructions
curl -X POST https://begemot.example.com/mcp \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -H "x-api-key: $BEGEMOT_API_KEY" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}'
```

Дальше `opencode mcp list` → `✓ begemot connected`, и в системном промпте
появляется `<mcp_instructions>` с протоколом рассуждения.
