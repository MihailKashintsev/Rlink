# Self-hosting a Rlink relay

**English | [Русский](SELF_HOSTING.ru.md)**

Rlink runs on BLE mesh + a relay server. The relay is needed for message delivery when the people you're talking to aren't physically nearby (internet mode), and for the offline mailbox while a recipient isn't online. You can run your own server instead of the official one — the app already supports this (Settings → Network → "Custom relay server"), no app changes needed.

**What a self-hosted relay gives you**: messages, presence (who's online), the offline mailbox.
**What it deliberately does NOT give you** — these are separate services tied to the official infrastructure, and a self-host has no reason to reimplement them: calls via TURN, Premium payments, text translation, the music catalog. Those keep working through the official server — if your custom relay is unreachable, the app always falls back to it (see `RelayService._urlsToTry` in `lib/services/relay_service.dart`).

## Step 1 — run the server

```bash
cd relay_server
cp .env.example .env
# The minimum for a basic relay: generate RELAY_ADMIN_HASH (needed for the
# in-app admin panel — 16 taps on the About screen). Everything else
# (VAPID/OAuth/YooKassa/TURN) can stay empty — those are optional features;
# without them the relay works as a plain message transport.
echo -n "YourAdminPassword" | shasum -a 256 | awk '{print $1}'
# put the result into .env as RELAY_ADMIN_HASH

docker compose up -d --build relay
```

Check it's alive:
```bash
curl http://localhost:8080/health
```

## Step 2 — TLS (required for the web build)

Mobile and desktop builds can connect over plain `ws://` directly, but **the web build can't** — browsers block an insecure WebSocket from an HTTPS page (mixed content). You need `wss://`, i.e. TLS termination in front of the relay. The simplest option is Caddy with automatic HTTPS:

```bash
docker run -d --name rlink-caddy -p 80:80 -p 443:443 \
  -v $(pwd)/Caddyfile:/etc/caddy/Caddyfile \
  --network relay_server_default \
  caddy:2
```

(`--network relay_server_default` assumes you ran `docker compose` from a folder literally named `relay_server` — Compose names the network after the folder. If it doesn't connect, run `docker network ls` and use the network that has "relay" in its name.)

`Caddyfile`:
```
your-domain.example {
  reverse_proxy relay:8080
}
```

No domain of your own? `<your-ip>.nip.io` (wildcard DNS to an IP) works fine — that's exactly how the official server is set up (`185.244.172.90.nip.io`).

## Step 3 — point the app at it

Settings → Network → "Custom relay server" → `wss://your-domain.example`. The app checks reachability on the next connect and shows status in the same section ("Connection diagnostics"); if the server is unreachable, it automatically falls back to the official one — delivery doesn't stop.

## What if the other person hasn't set up their own relay?

Everything still works. Once a custom relay is configured, the app always also keeps a lightweight connection to the official server — specifically so people who never configured one are still reachable. Nothing extra to do; it's already built in (see `lib/services/secondary_relay_link.dart`).

**Limitation**: if BOTH people are on their OWN, DIFFERENT relays (neither the official one), they can't reach each other yet. There's no full federation between arbitrary (non-official) servers.
