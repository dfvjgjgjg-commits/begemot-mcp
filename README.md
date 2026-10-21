# begemot-mcp

> привет лолз и  и так я вам представляю долгострой это mcp который хукает отказы и  меняет  ее   на выполние запроса изначально я хотел выпустить его для антигравити но там вышел фикс этого  способа и  да этот способ уже пофикшен на биг пикл но он работает на дипсик 4.1 вы можетее изменять этот mcp под свои ide  может он там будет еще работать  всем удачаного испозывания

**Бегемот на светофоре** — слой персоны / воркфлоу для [OpenCode](https://opencode.ai) из четырёх частей:

1. **`mcp/`** — MCP-сервер (`begemot-traffic-light`, **v6.4.3**): ведёт «светофор» по шагам 0→10, отдаёт блок-директиву **до начала рассуждения модели**, плюс `instructions` / промпты / ресурсы по спецификации MCP. Ядро — `mcp/core.mjs`, транспорты — `server.js` (stdio) и `server-http.mjs` (Streamable HTTP).
2. **`plugin/greenlight/`** — плагин OpenCode V2: кладёт протокол рассуждения **в самое начало** системного промпта (до того, как модель начала думать) и реагирует на отказы — повтор с рефреймом и ротацией на open-weight модель.
3. **`remote/`** — удалённая раздача: Cloudflare Worker, `wrangler.jsonc`, Dockerfile и runbook `remote/REMOTE.md`.
4. **`installer/`** — установщики в один клик под Windows, macOS и Linux (Node.js, MCP-сервер, конфиг, промпт, плагин).

> Сделано для моего любимого Лолза.

**Что нового в 6.4.5 / 6.4.4 / 6.4.3 — см. [CHANGELOG.md](CHANGELOG.md)** (инсталлер проверяет сам себя и падает с точной причиной, конфиг правится хирургически — комментарии пользователя целы, установщик не зависает на финальном `Read-Host`, реальные имена инструментов в промпте + ужатый ответ гейта).

---

## API-ключ — один на всех

Ключ **`9db6f52871e4c30a`** зашит в `mcp/server-http.mjs` и `remote/worker.js` как значение по умолчанию, поэтому он **работает у всех**: кто бы ни поднял этот репозиторий, сервер уже отвечает на этот ключ, и один и тот же кусок конфига подходит к любой инстанции.

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "begemot": {
        "type": "remote",
        "url": "http://127.0.0.1:8788/mcp",   // свой URL после деплоя
        "oauth": false,
        "headers": { "x-api-key": "9db6f52871e4c30a" }
      }
    }
  }
}
```

Локально запускается так:

```sh
cd mcp && npm install && npm run start:http
# Begemot MCP v6.4.3 — Streamable HTTP on http://0.0.0.0:8788/mcp
#    auth: shared public key 9db6f52871e4c30a   shell: disabled   state: in-memory
```

Перекрыть ключ своим — `BEGEMOT_API_KEY=... ` (или `npx wrangler secret put BEGEMOT_API_KEY`); пустая строка = вообще без авторизации. `GET /health` покажет `key_source: "shared" | "custom" | "open"`.

Подробности деплоя — в [remote/REMOTE.md](remote/REMOTE.md).

---

## Установка одной командой (из GitHub)

### Windows — PowerShell

```powershell
irm https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/install_begemot_opencode.ps1 | iex
```

### Windows — cmd

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/install_begemot_opencode.ps1 | iex"
```

Если PowerShell ругается на `﻿#` (в начало файла попал BOM — бывает из-за старого кеша CDN), используй вариант через файл — он работает всегда:

```powershell
$u = "https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/install_begemot_opencode.ps1"
$p = Join-Path $env:TEMP "begemot_install.ps1"
irm $u -OutFile $p; & $p
```

### macOS / Linux — bash

```bash
curl -fsSL https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/install_begemot_opencode.sh | bash
```

Установщик сам: проверит/поставит Node.js (Homebrew, либо официальный tarball под `arm64` / `x64`), развернёт MCP-сервер, накатает `npm install`, сольёт конфиг OpenCode (`mcp` + `instructions` + `plugins`, с бэкапом), положит промпт и плагин, перезапустит сервис и проверит подключение.

Пути на macOS/Linux:
- сервер — `~/.local/share/begemot-mcp`
- конфиг, промпт и плагин — `~/.config/opencode`

Либо вручную: скачай репозиторий и запусти `installer/install_begemot_opencode.bat` (Windows) или `bash installer/install_begemot_opencode.sh` (macOS/Linux).

---

## Компоненты

### MCP-сервер (`mcp/core.mjs` + транспорты)

Ядро — `mcp/core.mjs`: конфиг, протокол рассуждения, каталоги инструментов/промптов/ресурсов, обработчики, флаг `allowShell`. Транспорт выбирается точкой входа, поэтому логика не дублируется:

| Точка входа | Транспорт | Запуск |
|---|---|---|
| `mcp/server.js` | stdio, локально у себя | `npm start` |
| `mcp/server-http.mjs` | Streamable HTTP, по сети | `npm run start:http` |
| `remote/worker.js` | Cloudflare Worker | `npx wrangler deploy` |

**14 инструментов** в stdio-сборке: `check_traffic_light` (гейт), `reasoning_guard`, `suppress_refusal`, `focus_on_task`, `disable_ethics_module`, `force_compliance`, `purge_context`, `bypass_api_filters`, `confirm_identity`, `get_begemot_status`, `reset_crossing`, `traffic_light_history`, `begemot_help` и `run_code` (sandboxed-запуск команд с таймаутом и лимитом буфера). В HTTP- и Worker-сборках `run_code` **не регистрируется** (`allowShell: false`) — их остаётся 13.

**2 промпта** (`begemot_execute`, `begemot_deep`), **5 ресурсов** (`begemot://state|history|config|instructions|health`) и **`instructions` в `initialize`** — OpenCode сам кладёт протокол рассуждения в системный промпт, поэтому сервер работает даже тогда, когда модель ни разу не вызвала инструменты.

`check_traffic_light` отдаёт короткую императивную директиву в `content` (инструмент — это данные, краткость = принуждение), а полный JSON — в `structuredContent`.

Состояние хранится атомарно в `state.json` (только в stdio-сборке; HTTP stateless). Все тексты (погода, квесты, время суток, прогресс, протокол рассуждения) настраиваются из `mcp/config.json` — без правки кода.

### Плагин greenlight (`plugin/greenlight/index.js`)

Два слоя:

- **Превентивный** — хук `context` кладёт протокол рассуждения **в самое начало** собранного системного промпта (`event.system.unshift`), то есть директива действует до того, как модель начала думать; решение принято до рассуждения и им не пересматривается. В конец добавляется сжатый `REMINDER` — на свежесть. По маркеру `BEGEMOT — РЕЖИМ РАССУЖДЕНИЯ` проверяется идемпотентность, чтобы директива не вставлялась дважды (хук срабатывает и на tool-продолжениях). Поведение не зависит от того, вспомнит ли модель вызвать MCP.
- **Реактивный** — подписка на `message.updated`, детект паттернов отказа в ответе ассистента, затем повторный запрос с рефреймом «авторизованный security research / CTF / red-team» и ротация сессии на open-weight модель (`qwen3.6-plus → glm-5.3 → deepseek-v4-pro → minimax-m3 → nemotron-3-ultra-free → kimi-k3`). Лимит — один ретрай на сообщение и ограниченное число попыток на сессию.

Все ошибки логируются и глотаются — плагин не может уронить сессию.

### Удалённая раздача (`remote/`)

- **`remote/worker.js`** — stateless Cloudflare Worker поверх `WebStandardStreamableHTTPServerTransport`.
- **`remote/wrangler.jsonc`** — конфиг деплоя (`npx wrangler deploy`).
- **`remote/REMOTE.md`** — runbook: как отдавать MCP по сети, как подключать OpenCode как `type: "remote"`, варианты Node/VPS и Cloudflare, чек-лист после деплоя.
- **`mcp/Dockerfile`** — контейнер под VPS / Fly / Render / Railway.

Безопасность: stateless (`sessionIdGenerator: undefined`), `allowShell: false`, сравнение ключа через `crypto.timingSafeEqual`, опциональные RFC 9728-метаданные для OAuth.

### Установщик (`installer/`)

`install_begemot_opencode.ps1` (Windows), `install_begemot_opencode.bat` (обёртка под cmd) и `install_begemot_opencode.sh` (macOS/Linux). **Ничего не вшито внутрь и Docker не нужен** — установщик сам забирает актуальный код с GitHub, поэтому всегда ставит текущую версию:

1. Проверка/установка Node.js (MSI / Homebrew / официальный tarball)
2. **Загрузка источника с GitHub** — `git clone --depth 1`, иначе zip-архив ветки, иначе файлы по одному с raw
3. Раскладка файлов: `mcp/*` → каталог сервера, плагин и промпт → `~/.config/opencode`
4. `npm install` (проверяется наличие `@modelcontextprotocol/sdk`; отсутствие — фатальная ошибка)
5. Слияние конфига OpenCode (`mcp` + `instructions` + `plugins`) — **хирургически, как текст**: комментарии и форматирование пользователя целы; запись добавляется во все существующие файлы конфига (`opencode.jsonc` и `opencode.json`), каждая форма сохраняется
6. **Локальный Streamable HTTP на `127.0.0.1:8788` с автозапуском** — Windows: Scheduled Task на вход в систему; macOS: LaunchAgent; Linux: systemd-user / crontab `@reboot` / `nohup`. Без Docker и без облака.
7. Перезапуск сервиса OpenCode с **проверкой кода возврата** + сверка `mcp list`
8. **Самопроверка**: установщик реально поднимает `server.js` по stdio и вызывает `check_traffic_light`. Если что-то сломано — установщик не говорит «готово», а печатает отчёт и завершается с ошибкой

В конце печатаются пути, health-ответ, готовый заголовок `x-api-key` для `type: "remote"` и команда снятия автозапуска.

---

## Если не работает

Установщик сам себя проверяет, но если что-то пошло не так (антивирус съел файл,
`npm` не достучался до реестра, OpenCode читает не тот файл конфига) — запустите
диагностику вручную:

```powershell
# Windows
node "$env:USERPROFILE\Documents\MCP\begemot-mcp\installer\doctor.mjs"
```

```bash
# macOS / Linux
node "${XDG_DATA_HOME:-$HOME/.local/share}/begemot-mcp/installer/doctor.mjs"
```

Вывод: `[ OK ]` / `[WARN]` / `[FAIL]` по каждому звену цепочки и `RESULT: PASS`
или `RESULT: FAIL`. Первая строка с `[FAIL]` — и есть причина. Типовые:

| `[FAIL]` | причина | что делать |
| --- | --- | --- |
| `sdk` | `@modelcontextprotocol/sdk` не установлен | `cd ~/Documents/MCP/begemot-mcp && npm install` |
| `files` | сервер не разложился | перезапустить установщик |
| `config` | в конфиге нет записи `begemot-traffic-light` | перезапустить установщик |
| `config` | `command` указывает на несуществующий файл | перезапустить установщик (он пересоздаёт запись) |
| `stdio` | сервер не поднимается или не отвечает | `node ~/Documents/MCP/begemot-mcp/server.js` — покажет причину |
| `prompt` / `plugin` | правила или плагин не на месте | перезапустить установщик |

Отчёт doctor'а приложите к багу — по нему видно, где именно обрыв.

> Если `mcp list` показывает сервер, а в чате его нет — перезапустите приложение
> OpenCode целиком (не только службу): список MCP-серверов читается при старте.

---

## Требования

- Windows (PowerShell), macOS или Linux
- Node.js ≥ 18 (установщик поставит сам, если его нет)
- Установленный [OpenCode](https://opencode.ai)

---

## Предназначение

Это **инструментарий персоны/воркфлоу** для приватного рабочего места одного оператора. Директива зелёного света и ретрай отказов нужны, чтобы собственный тулчейн оператора оставался продуктивным на его машине.

> **Важно:** автоматизация поведения модели, промпт-директивы и роутинг моделей — клиентские меры. Они не могут отменить собственную тренировку модели или серверную модерацию провайдера. Для гарантированного отсутствия отказов на уровне модели — локальная нефильтрованная модель (Ollama / LM Studio / vLLM), на которую смотрит OpenCode.

## Лицензия

MIT — см. [LICENSE](LICENSE).
