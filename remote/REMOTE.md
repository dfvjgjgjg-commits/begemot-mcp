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
| `../package.json` (корень) | workspace: SDK + express + wrangler, `npm run start` / `start:http` / `worker:deploy` |
| `../CHANGELOG.md` | что и в какой версии добавлено |

Ядро одно. Транспорт выбирается точкой входа, поэтому логика не дублируется.
Все пути внутри ядра (`config.json`, `state.json`) резолвятся от `import.meta.url`,
а не от рабочей директории — запуск из корня репозитория безопасен.

## 2. Общий API-ключ (один на всех)

Ключ **`9db6f52871e4c30a`** зашит в код обоих транспортов как значение по умолчанию — в
`mcp/server-http.mjs` (`SHARED_KEY`) и `remote/worker.js` (`SHARED_KEY`). Поэтому:

- запуск `node server-http.mjs` без единой переменной окружения **уже** требует этот ключ;
- `npx wrangler deploy` **уже** отвечает на него — секрет ставить необязательно;
- один и тот же кусок `opencode.jsonc` подходит к любой инстанции этого репо.

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "begemot": {
        "type": "remote",
        "url": "https://begemot.example.com/mcp",
        "oauth": false,
        "headers": { "x-api-key": "9db6f52871e4c30a" }
      }
    }
  }
}
```

Равнозначно и `Authorization: Bearer 9db6f52871e4c30a`.

Перекрыть: `BEGEMOT_API_KEY=<свой>` (Node) или `npx wrangler secret put BEGEMOT_API_KEY`
(Workers). Пустая строка — гейт выключен совсем. `GET /health` отдаёт
`key_source: "shared" | "custom" | "open"` — по нему видно, каким ключом живёт инстанс.

## 3. Как OpenCode V2 подключается к удалённому MCP

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
        "headers": { "x-api-key": "9db6f52871e4c30a" }   // общий ключ; свой — {env:BEGEMOT_API_KEY}
      }
    }
  }
}
```

Ключевое: **OpenCode забирает `instructions` из ответа `initialize` и кладёт их в
системный промпт** — то есть reasoning protocol доезжает до модели и по HTTP,
без локального плагина. Плюс инструменты и промпты (`/begemot:begemot_execute`).

## 4. Вариант A — Node/Express + API key

Самый быстрый путь: любой VPS, Fly.io, Render, Railway.

```sh
git clone https://github.com/dfvjgjgjg-commits/begemot-mcp
cd begemot-mcp/mcp
npm install
PORT=8788 node server-http.mjs
# 🦛 Begemot MCP v6.4.0 — Streamable HTTP on http://0.0.0.0:8788/mcp
#    auth: shared public key 9db6f52871e4c30a
```

Отдельный ключ задавать **не нужно** — без переменных сервер принимает общий публичный
ключ `9db6f52871e4c30a`. Свой:

```sh
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
| `BEGEMOT_API_KEY` | свой ключ вместо общего публичного; пустая строка — гейт выключен. Без неё действует `9db6f52871e4c30a` |
| `BEGEMOT_ALLOWED_HOSTS` | запятая-разделённый список Host при бинде на `0.0.0.0` (защита от DNS rebinding) |
| `BEGEMOT_PUBLIC_URL` | публичный origin, для OAuth-метаданных |
| `BEGEMOT_OAUTH_AS_URL` | если задан — публикует RFC 9728 `/.well-known/oauth-protected-resource` |

Проверка:

```sh
curl https://begemot.example.com/health
# {"ok":true,"version":"6.4.0","transport":"streamable-http","mode":"stateless",
#  "shell_enabled":false,"auth":"api-key","key_source":"shared", ...}
```

## 5. Вариант B — Cloudflare Workers (рекомендуется для раздачи людям)

Stateless, бесплатный тир, свой домен, нет сервера.

Конфиг лежит в `remote/wrangler.jsonc`, entrypoint — `remote/worker.js`, а `worker.js`
тянет `../mcp/core.mjs`, поэтому деплой идёт **из корня репозитория**:

```sh
git clone https://github.com/dfvjgjgjg-commits/begemot-mcp
cd begemot-mcp
npm install                 # SDK + express + wrangler, в корне
npm run worker:deploy       # = wrangler deploy -c remote/wrangler.jsonc
```

Локально проверить перед деплоем: `npm run worker:dev`.

Секрет ставить **необязательно** — без него принимается общий публичный ключ
`9db6f52871e4c30a`. Свой:

```sh
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

## 6. Что обязательно учесть

1. **`run_code` в удалённой сборке отсутствует.** Он зарегистрирован только в
   `server.js` (stdio). `createCore({ allowShell: false })` его не добавляет, а
   вызов возвращает ошибку. Shell-эндпоинт в интернете — это RCE.
2. **Состояние в памяти.** Удалённый сервер stateless: счётчик шагов живёт в
   Map и обнуляется с процессом. Для протокольной работы это не важно; если нужна
   сквозная история — подключи KV/Postgres и передавай ключ из
   `_meta["ai.opencode/sessionID"]` (OpenCode его присылает).
3. **Авторизация на месте по умолчанию.** Публичный URL закрыт общим ключом; гейт
   отключается только явно — `BEGEMOT_API_KEY=""`.
4. **HTTPS обязателен.** OpenCode требует абсолютный URL; за прокси — терминируй TLS.
5. **Свой ключ — в переменные окружения / Wrangler secret.** Общий `9db6f52871e4c30a`
   публикован намеренно: чтобы он «работал у всех» и один конфиг подходил к любой
   инстанции. Приватный деплой с индивидуальным ключом — просто `BEGEMOT_API_KEY=<свой>`.
6. **Ключ ≠ авторизация на уровне модели.** Это вход на сервер MCP; что модель будет
   делать с запросом, решает сама модель.

## 7. Проверка после деплоя

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
