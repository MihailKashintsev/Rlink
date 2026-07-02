import 'dart:convert';

import '../models/bot_blueprint.dart';

/// Превращает [BotBlueprint] в готовый к запуску Python-файл.
///
/// Сгенерированный файл самодостаточен: он запекает правила (base64-JSON),
/// зависит только от пакета `rlink_bot` и читает `rlink_bot_config.json`
/// (создаётся шагом onboard). Пользователь разворачивает его локально или на
/// своём сервере — на relay ничего не исполняется.
class BotCodeGenerator {
  const BotCodeGenerator._();

  static String fileName(BotBlueprint bp) {
    final h = bp.sanitizedHandle.isEmpty ? 'bot' : bp.sanitizedHandle;
    final base = h.endsWith('bot') ? h : '${h}_bot';
    return 'rlink_$base.py';
  }

  /// Человекочитаемый rules-JSON (для повторного импорта в конструктор).
  static String rulesJson(BotBlueprint bp) => bp.toJsonString();

  /// Полный текст Python-файла бота.
  static String python(BotBlueprint bp) {
    final rulesB64 = base64Encode(utf8.encode(jsonEncode(bp.toJson())));
    final display = bp.name.isEmpty ? 'Rlink bot' : bp.name;
    final handle = bp.sanitizedHandle.isEmpty ? 'bot' : bp.sanitizedHandle;

    return '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
$display (@$handle) — бот Rlink, собранный в no-code конструкторе.

Правила запечены в этом файле (RULES ниже) — редактировать код не нужно.
Логика выполняется ТАМ, ГДЕ вы запускаете файл (ваш ПК или сервер), не на relay.

Запуск (после onboard, который создаёт rlink_bot_config.json):
    python ${fileName(bp)}

Другой конфиг/сервер:
    python ${fileName(bp)} --config rlink_bot_config.json --relay wss://...
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
import time
from pathlib import Path

from rlink_bot.crypto_rlink import BotKeys
from rlink_bot.relay_client import RelayBotSession
from rlink_bot.relay_defaults import DEFAULT_RELAY_WS

# ── Правила из конструктора (base64 — не редактировать вручную) ────────────────
_RULES_B64 = (
    "$rulesB64"
)
RULES = json.loads(base64.b64decode(_RULES_B64).decode("utf-8"))


# ── Движок ответов ─────────────────────────────────────────────────────────────

def _render_buttons(buttons) -> str:
    parts = []
    for b in buttons or []:
        label = str(b.get("label", "")).strip()
        command = str(b.get("command", "")).strip()
        if label and command:
            parts.append("[btn:%s|%s]" % (label, command))
    return " ".join(parts)


def _with_buttons(text: str, buttons) -> str:
    bar = _render_buttons(buttons)
    text = (text or "").rstrip()
    if bar:
        return (text + "\\n\\n" + bar) if text else bar
    return text


def _welcome() -> str:
    return _with_buttons(RULES.get("welcomeText", ""), RULES.get("welcomeButtons"))


def _fallback(original: str) -> str:
    if RULES.get("echoOnUnmatched"):
        return original
    return _with_buttons(RULES.get("fallbackText", ""), RULES.get("fallbackButtons"))


def reply_for(text: str) -> str:
    """Первое совпавшее правило выигрывает; иначе welcome/fallback."""
    t = (text or "").strip()
    low = t.lower()

    if t == "" or low in ("/start", "start", "/menu", "menu", "меню"):
        return _welcome()

    for rule in RULES.get("rules", []):
        pat = str(rule.get("pattern", "")).strip()
        if not pat:
            continue
        typ = rule.get("type", "command")
        matched = False
        if typ == "command":
            cmd = pat.lower()
            matched = low == cmd or low.startswith(cmd + " ")
        elif typ == "keyword":
            matched = pat.lower() in low
        elif typ == "exact":
            matched = low == pat.lower()
        if matched:
            return _with_buttons(rule.get("reply", ""), rule.get("buttons"))

    return _fallback(t)


def _command_list():
    seen = set()
    out = [("/start", "Меню"), ("/help", "Справка")]
    for c, _d in out:
        seen.add(c)
    for rule in RULES.get("rules", []):
        if rule.get("type") != "command":
            continue
        pat = str(rule.get("pattern", "")).strip().lower()
        if not pat.startswith("/") or pat in seen:
            continue
        desc = str(rule.get("reply", "")).strip().splitlines()[0] if rule.get("reply") else pat
        out.append((pat, desc[:60] or pat))
        seen.add(pat)
    return out


# ── Запуск (читает rlink_bot_config.json как `python -m rlink_bot run`) ──────────

def main() -> int:
    ap = argparse.ArgumentParser(description="$display (@$handle) — бот Rlink")
    ap.add_argument("--config", default="rlink_bot_config.json",
                    help="JSON из `python -m rlink_bot onboard` (по умолчанию rlink_bot_config.json)")
    ap.add_argument("--relay", default="", help="Переопределить relay wss://…")
    ap.add_argument("--no-commands", action="store_true",
                    help="Не публиковать список команд в профиль бота")
    args = ap.parse_args()

    cfg_path = Path(args.config).expanduser().resolve()
    if not cfg_path.exists():
        print("Нет %s. Сначала: python -m rlink_bot onboard <код> --file bot_keys.json"
              % cfg_path, file=sys.stderr)
        return 1
    try:
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    except Exception as e:
        print("Не читается конфиг %s: %s" % (cfg_path, e), file=sys.stderr)
        return 1

    keys_path = Path(cfg.get("keys_path") or "rlink_bot_keys.json").expanduser()
    if not keys_path.is_absolute():
        keys_path = (cfg_path.parent / keys_path).resolve()
    if not keys_path.exists():
        print("Нет файла ключей %s" % keys_path, file=sys.stderr)
        return 1

    relay = (args.relay or cfg.get("relay_url") or DEFAULT_RELAY_WS).strip()
    handle = str(cfg.get("handle") or "$handle").strip().lstrip("@")
    nick = "@" + handle[:32]
    api_token = str(cfg.get("api_token") or "").strip()

    keys = BotKeys.from_json_dict(json.loads(keys_path.read_text(encoding="utf-8")))
    sess = RelayBotSession(relay, keys)
    if api_token:
        sess.api_token = api_token

    print("[$handle] подключение %s nick=%s" % (relay, nick))
    try:
        sess.connect(nick=nick)
        if api_token and not args.no_commands:
            ack = sess.set_commands(_command_list())
            if ack.get("ok") is not True:
                print("[commands] не обновлены: %s" % ack, file=sys.stderr)
        print("[$handle] онлайн. Ctrl+C — стоп.")

        def on_dm(sender: str, text: str) -> None:
            print("[dm %s…] %d символов" % (sender[:8], len(text)), flush=True)
            try:
                sess.send_dm(sender, reply_for(text))
            except Exception as e:
                print("[send] %s" % e, file=sys.stderr, flush=True)
            time.sleep(0.05)

        sess.recv_loop(on_dm, log=lambda s: print(s, flush=True))
    except KeyboardInterrupt:
        print("bye")
    except Exception as e:
        print("сбой запуска: %s" % e, file=sys.stderr)
        return 1
    finally:
        sess.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
''';
  }
}
