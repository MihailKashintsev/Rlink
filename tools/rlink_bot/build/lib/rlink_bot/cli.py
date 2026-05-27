"""CLI: keys init | keys show-pub | onboard | claim | run | code"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import sys
import time
from pathlib import Path

from rlink_bot.bootstrap import claim_and_save_config, normalize_claim_from_lib
from rlink_bot.crypto_rlink import BotKeys
from rlink_bot.relay_client import RelayBotSession
from rlink_bot.relay_defaults import DEFAULT_RELAY_WS

DEFAULT_RELAY = os.environ.get("RLINK_RELAY_URL", DEFAULT_RELAY_WS)

_CLAIM_CODE_ALPHABET_STR = "23456789ABCDEFGHJKMNPRSTWXYZ"


def _keys_path(args: argparse.Namespace) -> Path:
    return Path(args.file).expanduser().resolve()


def cmd_keys_init(args: argparse.Namespace) -> int:
    p = _keys_path(args)
    if p.exists() and not args.force:
        print(f"Refusing to overwrite {p} (use --force)", file=sys.stderr)
        return 1
    keys = BotKeys.generate()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(keys.to_json_dict(), indent=2), encoding="utf-8")
    print(f"Wrote {p}")
    print("Ed25519 public (for Lib /newbot):", keys.ed25519_public_hex)
    return 0


def cmd_keys_show_pub(args: argparse.Namespace) -> int:
    p = _keys_path(args)
    if not p.exists():
        print(f"Missing {p}", file=sys.stderr)
        return 1
    d = json.loads(p.read_text(encoding="utf-8"))
    print(d.get("ed25519_public_hex") or BotKeys.from_json_dict(d).ed25519_public_hex)
    return 0


def _do_claim_save(args: argparse.Namespace, *, label: str) -> int:
    p = _keys_path(args)
    if not p.exists():
        print(f"Missing keys file {p}", file=sys.stderr)
        return 1
    relay = args.relay.strip()
    out = Path(args.out).expanduser().resolve()
    try:
        raw = args.claim_id.strip()
        normalize_claim_from_lib(raw)  # validate early
        cfg = claim_and_save_config(
            p,
            raw,
            relay=relay or None,
            out_path=out,
            nick=args.nick,
        )
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1
    except RuntimeError as e:
        print("claim failed:", e, file=sys.stderr)
        return 1
    except Exception as e:
        print(label, e, file=sys.stderr)
        return 1

    token = cfg.get("api_token")
    handle = cfg.get("handle")
    bot_id = cfg.get("bot_id")
    print("OK handle=@%s botId=%s" % (handle, bot_id))
    if token:
        print("API token saved to config.")
    print("Wrote", out)
    print("Relay:", cfg.get("relay_url"))
    return 0


def cmd_onboard(args: argparse.Namespace) -> int:
    """Claim с relay по умолчанию (как в приложении Rlink)."""
    print("Using relay:", args.relay.strip() or DEFAULT_RELAY_WS)
    return _do_claim_save(args, label="onboard:")


def cmd_claim(args: argparse.Namespace) -> int:
    return _do_claim_save(args, label="claim:")


def cmd_code(_args: argparse.Namespace) -> int:
    t = "".join(secrets.choice(_CLAIM_CODE_ALPHABET_STR) for _ in range(12))
    print(f"{t[0:4]}-{t[4:8]}-{t[8:12]}")
    return 0


def _btn(label: str, command: str) -> str:
    return f"[btn:{label}|{command}]"


def _btns(*pairs: tuple[str, str]) -> str:
    return " ".join(_btn(label, command) for label, command in pairs)


_DEFAULT_COMMANDS: list[tuple[str, str]] = [
    ("/start", "Главное меню"),
    ("/menu", "Главное меню"),
    ("/help", "Справка"),
    ("/ping", "Проверка связи"),
]


def _default_reply(text: str) -> str:
    t = text.strip().lower()
    menu = _btns(("Помощь", "/help"), ("Ping", "/ping"), ("Меню", "/menu"))
    if t in ("/start", "/menu", "start", "menu", "меню"):
        return "Бот онлайн. Выберите действие:\n\n" + menu
    if t in ("/help", "help", "помощь"):
        return (
            "Это базовый Python-бот Rlink.\n\n"
            "Замените функцию ответа в своём файле или используйте "
            "`tools/rlink_bot/example_echo_bot.py` как шаблон.\n\n"
            + menu
        )
    if t == "/ping":
        return "pong\n\n" + _btns(("Ещё ping", "/ping"), ("Меню", "/menu"))
    return f"Получил: {text[:240]}\n\n" + menu


def cmd_run(args: argparse.Namespace) -> int:
    p = Path(args.file).expanduser().resolve()
    if not p.exists():
        print(f"Missing {p}", file=sys.stderr)
        print(
            "Run onboard first: python -m rlink_bot onboard CLAIM_CODE --file bot_keys.json",
            file=sys.stderr,
        )
        return 1
    try:
        loaded = json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"Cannot read JSON {p}: {e}", file=sys.stderr)
        return 1

    config_mode = isinstance(loaded, dict) and (
        "relay_url" in loaded or "keys_path" in loaded or "bot_id" in loaded
    )
    if config_mode:
        cfg = loaded
        keys_path = Path(cfg.get("keys_path") or "rlink_bot_keys.json").expanduser()
        if not keys_path.is_absolute():
            keys_path = (p.parent / keys_path).resolve()
        relay = (args.relay or cfg.get("relay_url") or DEFAULT_RELAY_WS).strip()
        handle = str(cfg.get("handle") or "bot").strip().lstrip("@")
        nick = args.nick or f"@{handle[:32]}"
        api_token = str(cfg.get("api_token") or "").strip()
    else:
        cfg = {}
        keys_path = p
        relay = (args.relay or DEFAULT_RELAY_WS).strip()
        nick = args.nick or None
        api_token = ""

    if not keys_path.exists():
        print(f"Missing keys file {keys_path}", file=sys.stderr)
        return 1
    keys = BotKeys.from_json_dict(json.loads(keys_path.read_text(encoding="utf-8")))
    sess = RelayBotSession(relay, keys)
    if api_token:
        sess.api_token = api_token

    print(f"[rlink_bot] connecting {relay} nick={nick or '@' + keys.ed25519_public_hex[:10]}")
    try:
        sess.connect(nick=nick)
        if api_token and not args.no_commands:
            ack = sess.set_commands(_DEFAULT_COMMANDS)
            if ack.get("ok") is not True:
                print(f"[commands] not updated: {ack}", file=sys.stderr)
        print("[rlink_bot] online. Ctrl+C — stop.")

        def on_dm(sender: str, text: str) -> None:
            print(f"[dm {sender[:8]}…] received {len(text)} chars", flush=True)
            try:
                sess.send_dm(sender, _default_reply(text))
            except Exception as e:
                print(f"[send] {e}", file=sys.stderr, flush=True)
            time.sleep(0.05)

        sess.recv_loop(on_dm, log=lambda s: print(s, flush=True))
    except KeyboardInterrupt:
        print("bye")
    except Exception as e:
        print(f"run failed: {e}", file=sys.stderr)
        return 1
    finally:
        sess.close()
    return 0


def main() -> None:
    ap = argparse.ArgumentParser(prog="python -m rlink_bot")
    sub = ap.add_subparsers(dest="cmd", required=True)

    k = sub.add_parser("keys", help="Manage bot key file")
    ks = k.add_subparsers(dest="keys_cmd", required=True)
    ki = ks.add_parser("init", help="Generate new Ed25519 + X25519 keys")
    ki.add_argument("--file", default="rlink_bot_keys.json")
    ki.add_argument("--force", action="store_true")
    ki.set_defaults(func=cmd_keys_init)

    kp = ks.add_parser("show-pub", help="Print Ed25519 public hex (for Lib)")
    kp.add_argument("--file", default="rlink_bot_keys.json")
    kp.set_defaults(func=cmd_keys_show_pub)

    onboard = sub.add_parser(
        "onboard",
        help="Завершить регистрацию: вставьте claimId/claimCode из Lib (relay по умолчанию как в Rlink)",
    )
    onboard.add_argument(
        "claim_id",
        help="Скопируйте из ответа Lib после /newbot (32 hex или ABCD-EFGH-JKLM)",
    )
    onboard.add_argument("--file", default="rlink_bot_keys.json")
    onboard.add_argument(
        "--relay",
        default="",
        help=f"Необязательно; по умолчанию {DEFAULT_RELAY_WS}",
    )
    onboard.add_argument("--nick", default=None)
    onboard.add_argument("--out", default="rlink_bot_config.json")
    onboard.set_defaults(func=cmd_onboard)

    c = sub.add_parser(
        "claim",
        help="То же, что onboard: claim на relay (явный --relay при другом сервере)",
    )
    c.add_argument("claim_id")
    c.add_argument("--file", default="rlink_bot_keys.json")
    c.add_argument("--relay", default=DEFAULT_RELAY)
    c.add_argument("--nick", default=None)
    c.add_argument("--out", default="rlink_bot_config.json")
    c.set_defaults(func=cmd_claim)

    sub.add_parser(
        "code",
        help="Print a random claimCode-style string (demo only)",
    ).set_defaults(func=cmd_code)

    r = sub.add_parser(
        "run",
        help="Run a simple ready-to-use DM bot from onboard config or keys JSON",
    )
    r.add_argument(
        "--file",
        default="rlink_bot_config.json",
        help="rlink_bot_config.json из onboard или файл ключей бота",
    )
    r.add_argument("--relay", default=DEFAULT_RELAY)
    r.add_argument("--nick", default=None)
    r.add_argument(
        "--no-commands",
        action="store_true",
        help="Не публиковать стандартные slash-команды при старте",
    )
    r.set_defaults(func=cmd_run)

    args = ap.parse_args()
    raise SystemExit(args.func(args))
