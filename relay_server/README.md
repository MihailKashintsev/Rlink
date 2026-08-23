# rlink-relay

**English | [Русский](README.ru.md)**

The relay server for [Rlink](https://github.com/MihailKashintsev/Rlink), a mesh + relay hybrid messenger. A small, dependency-light Dart WebSocket server — it routes end-to-end encrypted packets between clients by public key, holds an offline mailbox for recipients who aren't connected, and optionally forwards web push notifications. It never sees plaintext and never holds a private key; if this server were fully compromised, the worst it leaks is metadata (who's online, packet sizes/timing), not message content.

This is a genuine zero-knowledge relay, not a marketing claim: read [`bin/server.dart`](bin/server.dart) — there's no code path that decrypts a client-to-client message.

## What it does

- **Message routing**: directed delivery by public key, or flood-broadcast for presence-style packets — mirrors the client's own `GossipRouter` packet model (see the main [Rlink repo](https://github.com/MihailKashintsev/Rlink)).
- **Offline mailbox**: queues packets for a recipient who isn't currently connected, replays them on reconnect.
- **Presence**: online/away status between contacts.
- **Web push**: VAPID-based push for the web client when a tab is closed.
- **Admin panel backend**: a password-gated in-app admin surface (reachable via 16 taps on the app's About screen) for moderation/config, guarded by `RELAY_ADMIN_HASH`.
- **Optional, separable features** — none of the above depends on these: Google Drive OAuth backend (durable Drive linking for channel backups), Rlink Premium via YooKassa, a bot directory.

## Running your own

See **[SELF_HOSTING.md](SELF_HOSTING.md)** for the 5-minute path: `docker compose up`, point the app's "Custom relay server" setting at it. A self-hosted relay gives you messages, presence, and the offline mailbox — calls/TURN, Premium payments, translation, and the music catalog stay tied to the official deployment by design (a self-host has no reason to reimplement those).

For the project's own TURN deployment specifically (not general self-hosting), see [README_TURN.md](README_TURN.md).

## Development

```bash
dart pub get
dart run bin/server.dart
```

Reads configuration from environment variables — copy `.env.example` to `.env` and fill in what you need; everything except `RELAY_ADMIN_HASH` is optional (the server runs as a plain message transport without it).

## License

GPL-3.0 — see [LICENSE](LICENSE).
