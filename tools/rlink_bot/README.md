# Rlink Bot SDK

Python SDK для разработчиков сторонних ботов Rlink.

Бот в Rlink — это отдельный процесс со своими ключами Ed25519/X25519. Он
подключается к relay по WebSocket, получает личные сообщения, расшифровывает их
локально и отвечает обратно E2E-сообщением. Регистрация бота делается через
официального бота **Lib** в приложении Rlink.

Relay по умолчанию совпадает с приложением:

```text
wss://185.244.172.90.nip.io
```

`--relay` нужен только для своего relay.

В примерах ниже используется `python`. На macOS/Linux, где такого alias нет,
используйте `python3` в тех же командах.

## Быстрый путь от кода к запуску

### 1. Установите SDK

```bash
cd tools/rlink_bot
python -m pip install -e .
```

Windows PowerShell:

```powershell
cd tools\rlink_bot
python -m pip install -e .
```

### 2. Создайте ключи бота

```bash
python -m rlink_bot keys init --file bot_keys.json
python -m rlink_bot keys show-pub --file bot_keys.json
```

Скопируйте строку из `keys show-pub`: это публичный Ed25519 ключ бота, ровно
64 hex символа. Файл `bot_keys.json` содержит приватные ключи, его нельзя
публиковать или отдавать пользователям.

### 3. Зарегистрируйте бота через Lib

В приложении Rlink откройте чат с **Lib** и отправьте:

```text
/newbot my_bot
```

Следующим сообщением вставьте публичный ключ из `keys show-pub`.

Можно одной строкой:

```text
/newbot my_bot <64hex_public_key>
```

Lib создаст заявку на relay и пришлёт:

- `claimCode` — короткий код вида `ABCD-EFGH-JKLM`;
- `claimId` — 32 hex;
- срок действия заявки, сейчас 15 минут.

### 4. Завершите onboarding на машине бота

Вставьте `claimCode` или `claimId` из Lib:

```bash
python -m rlink_bot onboard ABCD-EFGH-JKLM --file bot_keys.json
```

Команда подключится к relay ключом бота, выполнит `bot_claim` и создаст рядом
`rlink_bot_config.json`. `API token` сохраняется в конфиг и не печатается в
stdout.

### 5. Запустите готового бота

Самый короткий smoke test:

```bash
python -m rlink_bot run --file rlink_bot_config.json
```

Команда запускает простого DM-бота, публикует базовые slash-команды
`/start`, `/menu`, `/help`, `/ping` и отвечает пользователям, пока процесс
работает.

Пользователь в Rlink ищет бота по `@my_bot`, открывает чат и пишет `/start`.
Бот должен быть онлайн на том же relay.

## Написать свою логику

Скопируйте `example_echo_bot.py` и меняйте функцию `handle`.

```bash
python example_echo_bot.py --config rlink_bot_config.json
```

Минимальная схема:

```python
from pathlib import Path
import json

from rlink_bot.crypto_rlink import BotKeys
from rlink_bot.relay_client import RelayBotSession

cfg = json.loads(Path("rlink_bot_config.json").read_text(encoding="utf-8"))
keys = BotKeys.from_json_dict(
    json.loads(Path(cfg["keys_path"]).read_text(encoding="utf-8"))
)

sess = RelayBotSession(cfg["relay_url"], keys)
sess.connect(nick="@" + cfg["handle"])

def on_dm(sender: str, text: str) -> None:
    if text.strip().lower() in ("/start", "/menu"):
        sess.send_dm(sender, "Привет. Напишите любой текст.")
    else:
        sess.send_dm(sender, f"Эхо: {text}")

sess.recv_loop(on_dm)
```

Важное ограничение: `send_dm()` может ответить только когда SDK знает X25519
ключ пользователя. Обычно он приходит через presence после открытия чата или
поиска бота пользователем.

## Кнопки в сообщениях

Rlink показывает action-кнопки прямо в пузыре сообщения. Кнопка кодируется
текстовым токеном:

```text
[btn:Метка|/команда]
```

Несколько кнопок:

```text
Выберите действие:
[btn:Меню|/menu] [btn:Помощь|/help] [btn:Ping|/ping]
```

При нажатии клиент отправит `/команда` в чат с ботом как обычное сообщение.

Python helper:

```python
def btns(*pairs: tuple[str, str]) -> str:
    return " ".join(f"[btn:{label}|{cmd}]" for label, cmd in pairs)

sess.send_dm(
    user_id,
    "Главное меню\n\n" + btns(("Помощь", "/help"), ("Ping", "/ping")),
)
```

## Slash-команды в профиле бота

Команды можно опубликовать двумя путями:

1. Через Lib:

```text
/setcommands @my_bot /start Главное меню, /help Справка, /ping Проверка связи
```

2. Из процесса бота через SDK, если в конфиге есть `api_token`:

```python
sess.api_token = cfg["api_token"]
sess.set_commands([
    ("/start", "Главное меню"),
    ("/help", "Справка"),
    ("/ping", "Проверка связи"),
])
```

`python -m rlink_bot run` делает это автоматически для базовых команд.

## Форматирование текста

Клиент поддерживает Markdown-подобный синтаксис:

| Синтаксис | Результат |
|-----------|-----------|
| `**текст**` | жирный |
| `_текст_` | курсив |
| `__текст__` | подчёркнутый |
| `~~текст~~` | зачёркнутый |
| `` `код` `` | моноширинный |
| ` ```python ... ``` ` | блок кода |
| `||текст||` | спойлер |

Пример:

```python
sess.send_dm(
    user_id,
    "**Результат:**\n\n```python\nprint('Hello, Rlink')\n```\n\n"
    "[btn:Меню|/menu]",
)
```

## Управление ботом через Lib

Владелец бота может управлять ботами из чата с Lib:

| Команда | Что делает |
|---------|------------|
| `/mybots` | Список ваших ботов на текущем relay |
| `/setname @ник имя` | Отображаемое имя, 1-64 символа |
| `/setdesc @ник текст` | Описание, до 512 символов; пустой текст очищает |
| `/setavatar @ник [url]` | URL аватара или сброс без URL |
| `/setbanner @ник [url]` | URL баннера или сброс без URL |
| `/setcommands @ник ...` | Команды для профиля и автодополнения |
| `/delbot @ник` | Отозвать бота из каталога relay |

Lib подписывает запросы ключом владельца, поэтому приватный ключ бота для этих
правок не нужен.

## HTTP Bot API

HTTP Bot API сейчас управляет публичными метаданными и токеном. Сообщения
пользователей доставляются не через HTTP, а через WebSocket-сессию бота.

Базовый URL строится из relay:

- `wss://example` -> `https://example`
- `ws://127.0.0.1:8080` -> `http://127.0.0.1:8080`

Примеры:

```bash
BASE="http://127.0.0.1:8080"
TOKEN="api_token_from_onboard"

curl -X POST "$BASE/bot-api/v1/setMyName" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"displayName":"Echo Bot"}'

curl -X POST "$BASE/bot-api/v1/setMyDescription" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"description":"Пример стороннего бота Rlink"}'

curl -X POST "$BASE/bot-api/v1/setMyAvatarUrl" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com/avatar.png"}'
```

Методы:

| Метод | Тело |
|-------|------|
| `setMyName` | `{"displayName":"..."}` |
| `setMyDescription` | `{"description":"..."}` |
| `setMyAvatarUrl` | `{"url":"https://..."}` |
| `setMyBannerUrl` | `{"url":"https://..."}` |
| `setWebhook` | `{"url":"https://..."}`; URL сохраняется в каталоге, доставка сообщений через webhook пока не является основным путём |
| `deleteWebhook` | `{}` |
| `revokeToken` | `{}`; вернёт новый `apiToken` |

Каждый вызов попадает в историю активности бота в админке relay.

## Файлы и секреты

| Файл | Назначение |
|------|------------|
| `bot_keys.json` | Приватные ключи бота. Не коммитить |
| `rlink_bot_config.json` | Relay, handle, botId, путь к ключам, API token |
| `example_echo_bot.py` | Рабочий пример с меню, кнопками и эхо-режимом |

Рекомендуемый `.gitignore` для проекта бота:

```gitignore
bot_keys.json
rlink_bot_config.json
*_keys.json
*_config.json
```

## Структура SDK

| Файл | Что делает |
|------|------------|
| `rlink_bot/relay_client.py` | WebSocket-сессия: `connect`, `send_dm`, `recv_loop`, `set_commands` |
| `rlink_bot/crypto_rlink.py` | Ключи Ed25519/X25519 и E2E-шифрование DM |
| `rlink_bot/bootstrap.py` | `onboard`: claim из Lib и запись конфига |
| `rlink_bot/cli.py` | CLI: `keys`, `onboard`, `claim`, `run`, `code` |

## Типичные ошибки

### `Missing keys file`

Проверьте путь в `--file` и поле `keys_path` в `rlink_bot_config.json`.

### `claim_not_found`

Заявка из Lib истекла или код скопирован неверно. Повторите `/newbot` в Lib и
сразу выполните `onboard`.

### `wrong_bot_connection`

Вы делаете `onboard` не тем `bot_keys.json`, публичный ключ которого отправляли
в Lib. Создайте новую заявку или используйте правильный файл ключей.

### `No x25519 for peer ...`

Бот ещё не видел presence пользователя. Пользователь должен открыть чат с ботом
на том же relay и отправить сообщение; после появления X25519 ключа ответ
зашифруется и уйдёт.

### Windows: `No module named 'websocket'`

Установите зависимости в тот же Python:

```powershell
python -m pip install -e .
python -m pip install "websocket-client>=1.7" "cryptography>=42"
```

## Админка relay

Админ relay видит для каждого стороннего бота:

- уникальный код бота;
- handle, имя, описание, avatar/banner URL;
- online/last seen;
- счётчики входящих и исходящих сообщений, подключений и HTTP Bot API;
- последние события: claim, connect/disconnect, messages, commands, API calls;
- флаги `verified`, `blocked`, `revoked`.

Блокировка отключает активное WebSocket-соединение бота. `revoked` удаляет бота
из публичного каталога; повторная регистрация делается через новый `/newbot`.
