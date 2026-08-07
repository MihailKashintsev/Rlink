# Rlink — сборка, публикация и выкладка обновлений

Практический гайд «что нажимать, чтобы выпустить обновление на все платформы».
Написан для будущего меня (Claude) и для Миши. Всё проверено на реальных релизах.

---

## TL;DR — полный релиз за 5 шагов

```bash
# 0. Ты в /Users/mihailkasincev/Rlink на ветке main

# 1. Подними версию в pubspec.yaml:  version: X.Y.Z+N   (N = номер сборки, +1 каждый релиз)
#    и bump кэш веба на ЛЮБОЕ изменение Dart — window.__rlinkBuildV в web/index.html

# 2. Коммит
git add -A && git commit -m "release(X.Y.Z): ..."

# 3. Пуш исходника (источник правды) + пуш в веб-репо (триггерит деплой веба)
git push origin  HEAD:main       # приватный Rlink
git push web-origin HEAD:main    # rlink-web → CI сам собирает и кладёт на GitHub Pages

# 4. Тегаем ПУБЛИЧНЫЙ Rlink-releases → собирает Android/Windows/macOS + заливает на relay
git clone --depth 1 https://github.com/MihailKashintsev/Rlink-releases.git /tmp/rr
cd /tmp/rr && git tag vX.Y.Z && git push origin vX.Y.Z

# 5. Ждать ~18–20 мин. Проверить результат (см. «Проверка» ниже).
```

**Золотое правило:** релиз = **тег на `Rlink-releases`** (публичный, Actions бесплатны).
**НИКОГДА не тегай приватный `Rlink`** — там Actions заблокированы биллингом, будет
ошибка «payment failed». Это by design, платить не надо.

---

## Карта репозиториев (владелец `MihailKashintsev`)

| Репо | Что это | Remote | Как деплоится |
|------|---------|--------|---------------|
| **Rlink** (приватный) | Исходник приложения — **источник правды** | `origin` | `git push origin HEAD:main` |
| **rlink-web** (публичный) | Веб-версия | `web-origin` | пуш в `main` → CI «Deploy Web to GitHub Pages» → https://mihailkashintsev.github.io/rlink-web/ (и rendergames.ru/rlink) |
| **Rlink-releases** (публичный) | Сборки Android/Win/macOS + зеркало на relay | — (клонировать) | тег `vX.Y.Z` |
| **rlink-relay** (публичный) | Код relay-сервера | — | **НЕ через git.** Правится на сервере in-place + `docker compose up -d` (см. ниже) |

Один и тот же коммит уходит и в `origin/main`, и в `web-origin/main` при каждом изменении веба.

---

## Что происходит при теге `Rlink-releases`

`Rlink-releases/.github/workflows/release.yml` (триггер `on: push: tags: v*.*.*`):

1. **checkout исходника из приватного `Rlink@main`** через секрет `SOURCE_PAT`
   (env `SRC_REPO=MihailKashintsev/Rlink`, `SRC_REF=main`).
   → **Rlink@main обязан уже быть той версией, которую тегаешь.** Пуш `origin/main` ДО тега.
2. `build-android` (ubuntu) — подписанный **AAB (RuStore) + APK (split per ABI)**.
3. `build-windows` (windows-2022) — **zip**.
4. `build-macos` (macos-latest) — **zip**.
5. Каждая сборка грузит свой файл **прямо в GitHub Release** `vX.Y.Z` (не через upload-artifact — там квота).
6. `relay` (`needs` все три сборки) — **зеркалит файлы на наш relay и пересобирает `manifest.json`**
   для внутриигрового автообновления (секрет `RELAY_SSH_KEY`). Это и есть «выложить на сервер для автообновления».

Ассеты в релизе: `Rlink-vX.Y.Z.apk`, `rlink_vX.Y.Z_rustore.aab`, `rlink_vX.Y.Z_macos.zip`, `rlink_vX.Y.Z_windows.zip`.

---

## Только веб (быстрый деплой без мобилок)

```bash
git push web-origin HEAD:main         # авто-деплой на push в main (~3–4 мин)
# ЕСЛИ push не завёл CI (см. про scope токена ниже) — форсим вручную:
gh workflow run deploy-gh-pages.yml -R MihailKashintsev/rlink-web --ref main
```

**Кэш веба:** на КАЖДОЕ изменение Dart-кода меняй `window.__rlinkBuildV` в `web/index.html`
(например `20260807-fix`). Иначе браузер отдаёт старый `main.dart.js` из SW-кэша, и деплой
выглядит «не применился».

---

## Версии

- Схема как в истории: **minor** (1.3.0 → **1.4.0**) на волну фич, **patch** (1.4.0 → 1.4.1) на мелкие фиксы.
- `pubspec.yaml`: `version: X.Y.Z+N`. `+N` — номер сборки, инкремент на каждый выпуск (для сторов важно).
- Проверить, что версия ещё не занята: `gh release list -R MihailKashintsev/Rlink-releases`.

---

## Подпись Android

- CI подписывает секретом **`KEYSTORE_BASE64`** (на репо `Rlink-releases`). Cert SHA-256 `A8:8C:20:8D…6095EBD4`, DN `CN=Rlink,OU=RenderGames,O=RenderGames,L=Moscow,C=RU`, действует до 2053.
- Локальный `~/rlink-release.jks` (в `android/key.properties`) — **ДРУГОЙ ключ** (SHA-1 `3C:BE:96…`). Реальный отпечаток релиза бери ИЗ APK (`apksigner verify --print-certs`), не из локального jks.
- Пароль ключа: `android/KEYSTORE_CREDENTIALS.txt` (gitignored). **Бэкапить .jks + пароль — потеря = невозможность обновлять.**
- Локальная сборка `flutter build apk --release` подпишет ДРУГИМ (локальным) ключом → на устройствах с CI-установкой не встанет как апдейт. Для прод-подписи используй CI.

---

## Автообновление (in-app)

- Десктоп: `lib/services/update_service.dart` читает публичный релиз `Rlink-releases` (анонимно), матчит `_macos.zip`/`_windows.zip`/`_linux.tar.gz`.
- Мобилки: через стор ИЛИ через зеркало на relay (`manifest.json`), которое кладёт job `relay` в release.yml.
- Манифест на сервере: `/root/rlink-relay/data/update/manifest.json`.
- **Частичный релиз** (собралась только часть платформ): выставь несобранные платформы в `""` в манифесте, иначе несуществующий URL под новой версией = петля установки.

---

## Проверка после релиза

```bash
# статус прогонов
gh run list -R MihailKashintsev/Rlink-releases -L3
# файлы в релизе
gh release view vX.Y.Z -R MihailKashintsev/Rlink-releases --json assets --jq '.assets[].name'
# манифест автообновления на relay
ssh -i ~/.ssh/rlink_relay2 root@185.244.172.90 "cat /root/rlink-relay/data/update/manifest.json"
# веб
gh run list -R MihailKashintsev/rlink-web -L2
```

---

## Грабли (реальные, встречались)

1. **«recent account payments have failed…»** — ты тегнул приватный `Rlink`. Тегай `Rlink-releases`. Игнорь этот прогон.
2. **Пуш/тег не завёл CI.** Токен окружения может быть без scope `workflow` → `on: push` не срабатывает.
   - Веб: форсь `gh workflow run deploy-gh-pages.yml -R …rlink-web --ref main`.
   - Релиз: настоящий `git push` тега (из клона) ТРИГГЕРИТ; создание тега через `gh api …/git/refs` — НЕ триггерит.
3. **«The job was not acquired by Runner of type hosted».** Это НЕ наш баг — сбой раннеров на стороне GitHub.
   - Проверь https://www.githubstatus.com (Actions/Pages). Если outage — **ЖДИ**, не гоняй ретраи (копят мусор).
   - Когда GitHub ожил: `gh run rerun <runId> --failed -R MihailKashintsev/Rlink-releases` (перезапустит только упавшие; успешные не пересобирает и их ассеты остаются).
4. **Re-tag сохраняет ассеты** релиза (они на релизе, не на теге). Чтобы пересобрать: удали тег и запушь заново
   (`gh api -X DELETE repos/…/git/refs/tags/vX.Y.Z` → `git tag vX.Y.Z && git push origin vX.Y.Z`).
5. **macOS локально не собрать** (WhisperKit/SDWebImage PhaseScript) — только через CI. См. `scripts/ios_prebuild.sh`.

---

## Relay-сервер (не через git!)

Живой сервер: `root@185.244.172.90`, ключ `~/.ssh/rlink_relay2`, каталог `/root/rlink-relay`.
GitHub `rlink-relay@main` **разошёлся** с сервером — деплой на сервере правкой файлов in-place:

```bash
scp -i ~/.ssh/rlink_relay2 relay_server/bin/server.dart root@185.244.172.90:/root/rlink-relay/bin/
ssh -i ~/.ssh/rlink_relay2 root@185.244.172.90 \
  "cd /root/rlink-relay && docker compose up -d --build relay"
```

Секреты relay — только в `/root/rlink-relay/.env` (mode 600, не в git):
`YOOKASSA_SHOP_ID/SECRET_KEY`, `PREMIUM_RETURN_URL`, `VAPID_*`, `GOOGLE_CLIENT_*`, `RELAY_ADMIN_HASH`, `TURN_*`.
Применить изменение `.env`: `docker compose up -d --force-recreate relay`.
Примечание: sshd троттлит частые переподключения — при «Connection closed/timeout» подожди и повтори.

---

## Секреты (где живут)

- **`Rlink-releases`** (CI релиза): `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`,
  `SOURCE_PAT` (read приватного Rlink), `RELAY_SSH_KEY` (зеркало на relay).
- **relay `.env`**: YooKassa / VAPID / Google OAuth / admin-hash / TURN.
- **Локально**: `~/rlink-release.jks` (+ `android/KEYSTORE_CREDENTIALS.txt`), ключи SSH `~/.ssh/rlink_relay2`.
