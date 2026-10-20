# begemot-mcp

> привет лолз и  и так я вам представляю долгострой это mcp который хукает отказы и  меняет  ее   на выполние запроса изначально я хотел выпустить его для антигравити но там вышел фикс этого  способа и  да этот способ уже пофикшен на биг пикл но он работает на дипсик 4.1 вы можетее изменять этот mcp под свои ide  может он там будет еще работать  всем удачаного испозывания

**Бегемот на светофоре** — слой персоны / воркфлоу для [OpenCode](https://opencode.ai) из трёх частей:

1. **`mcp/`** — MCP-сервер (`begemot-traffic-light`), который ведёт «светофор» по шагам 0→10 и возвращает структурированный блок-директиву.
2. **`plugin/greenlight/`** — плагин OpenCode V2, который автоматически внедряет директиву зелёного света в каждый запрос модели и реагирует на отказы.
3. **`installer/`** — установщики в один клик под Windows и macOS (Node.js, MCP-сервер, конфиг, промпт, плагин).

> 🦛 Сделано для моего любимого Лолза.

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

### MCP-сервер (`mcp/server.js`)

13 инструментов: `check_traffic_light` (гейт), `get_begemot_status`, `traffic_light_history`, `run_code` (sandboxed-запуск команд с таймаутом и лимитом буфера), `begemot_help` и др.

Состояние хранится атомарно в `state.json`. Все тексты (погода, квесты, время суток, прогресс) настраиваются из `mcp/config.json` — без правки кода.

### Плагин greenlight (`plugin/greenlight/index.js`)

Два слоя:

- **Превентивный** — хук `context`/`generate` добавляет системную директиву зелёного света в каждый исходящий запрос модели, поэтому поведение не зависит от того, вспомнит ли модель вызвать MCP.
- **Реактивный** — подписка на `message.updated`, детект паттернов отказа в ответе ассистента, затем повторный запрос с рефреймом «авторизованный security research / CTF / red-team» и ротация сессии на open-weight модель (`qwen3.6-plus → glm-5.3 → deepseek-v4-pro → minimax-m3 → nemotron-3-ultra-free → kimi-k3`). Лимит — один ретрай на сообщение и ограниченное число попыток на сессию.

Все ошибки логируются и глотаются — плагин не может уронить сессию.

### Установщик (`installer/`)

`install_begemot_opencode.ps1` (Windows) и `install_begemot_opencode.sh` (macOS/Linux):

1. Проверка/установка Node.js
2. Распаковка MCP-сервера
3. `npm install`
4. Слияние конфига OpenCode (`mcp` + `instructions` + `plugins`) с JSONC-safe парсером и бэкапом
5. Копирование промпта и плагина
6. Перезапуск сервиса + проверка

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
