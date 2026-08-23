# Rlink

**English | [Русский](README.ru.md)**

Rlink is a cross-platform messenger built around two ideas most messengers don't take seriously: you shouldn't need a working internet connection to talk to someone standing near you, and you shouldn't need a phone number to have an identity.

- **Bluetooth mesh + relay, working together.** Messages flood through nearby devices over BLE (and Wi-Fi Direct on Android) when there's no internet, and fall back to a WebSocket relay when there is. The relay never sees plaintext — it's a zero-knowledge pass-through and offline mailbox, not a server that reads your messages.
- **No phone number.** Your identity is an Ed25519 keypair generated on-device. Contacts are added by exchanging a QR code or a pairing link, not by handing a phone number to a server.
- **End-to-end encrypted**, including a from-scratch Double Ratchet implementation (forward secrecy + post-compromise security) for 1:1 chats, safety-number verification, and encrypted call signaling.
- **Runs everywhere**: Android, iOS, Windows, macOS, Linux, and web, from one Flutter codebase.

This is a solo-developer, actively-evolving project — expect rough edges, and see [Known limitations](#known-limitations) before assuming a feature works the way a mature messenger's would.

## Why mesh + relay, not just one or the other

A pure mesh network (like older walkie-talkie-style apps) is great until everyone you want to reach is more than a few Bluetooth hops away. A pure relay-based messenger works anywhere there's internet, but stops working the moment there isn't — during a natural disaster, in a subway tunnel, at a protest where mobile networks get throttled, or just in a basement with no signal.

Rlink's `GossipRouter` treats both as equally first-class transports. A message gets flooded to every BLE-mesh peer and relay connection a device currently has, deduplicated by a seen-packet cache, and bounded by a hop-count TTL — the same message might arrive via three different paths and that's fine, it's just delivered once. See [`lib/services/gossip_router.dart`](lib/services/gossip_router.dart) for the actual routing logic, and [`relay_server/`](relay_server/) for the relay side.

## Architecture at a glance

```
┌─────────────┐        BLE / Wi-Fi Direct        ┌─────────────┐
│  Rlink app  │◄────────────────────────────────►│  Rlink app  │
│  (device A) │                                   │  (device B) │
└──────┬──────┘                                   └──────┬──────┘
       │                  WebSocket                      │
       └───────────────►┌───────────┐◄───────────────────┘
                         │   relay   │
                         │  server   │  (zero-knowledge — sees
                         └───────────┘   ciphertext + routing only)
```

- **Client** (this repo): Flutter app, all four native platforms plus web. `lib/services/` holds the transport (`ble_service.dart`, `relay_service.dart`, `gossip_router.dart`), crypto (`crypto_service.dart`, `double_ratchet.dart`), and storage layers; `lib/ui/` is the UI.
- **Relay server**: a small, dependency-light Dart WebSocket server ([mirror: `rlink-relay`](https://github.com/MihailKashintsev/rlink-relay), also vendored at [`relay_server/`](relay_server/) in this repo) that routes packets by public key and holds an offline mailbox. It never has your private keys and never decrypts a message. See [`relay_server/SELF_HOSTING.md`](relay_server/SELF_HOSTING.md) to run your own.
- **Web build**: mirrored to [`rlink-web`](https://github.com/MihailKashintsev/rlink-web) for GitHub Pages hosting.
- **Signed release binaries**: published to [`Rlink-releases`](https://github.com/MihailKashintsev/Rlink-releases) by CI on every version tag.

## Features

- 1:1 chats, groups, and broadcast-style channels
- Voice/video calls (WebRTC, with a self-hostable TURN server for NAT traversal)
- A sticker system with three formats: raster (`.rls`), a small in-app vector animation studio (`.rlv`), and Telegram `.tgs` import — plus in-editor background removal and photo-to-vector tools
- Custom emoji packs, emoji-triggered sticker/emoji suggestions in the composer
- A no-code bot constructor (rules → generated Python, run locally) and a relay-hosted bot directory
- Linked devices (mirror your account to a second device) and an account-transfer flow (move your identity to a new device)
- Optional Google Drive backup for channel/group history
- Optional Rlink Premium (nickname color, extra features) via a self-hosted YooKassa integration — entirely optional, the messaging core doesn't depend on it

## Security model

- Identity: Ed25519 (signing) + X25519 (key exchange), generated and stored on-device.
- 1:1 messages: Double Ratchet ([`lib/services/double_ratchet.dart`](lib/services/double_ratchet.dart)) once both sides' clients support it, falling back to a signed, fresh-ephemeral-ECDH-per-message scheme otherwise. See the file's doc comment for the exact scope-cut versus a full X3DH handshake.
- Call signaling is encrypted and signed the same way; media itself is protected by WebRTC's own DTLS-SRTP, so even a malicious TURN relay can't read it.
- Safety numbers let two contacts verify they're actually talking to each other, not to a MITM'd key.
- The relay is deliberately kept dumb: it authenticates connections by public key, routes ciphertext, and queues for offline recipients — it has nothing meaningful to leak even if fully compromised, except metadata (who's online, packet timing/sizes).

This is not a professionally audited cryptographic implementation. Treat it accordingly, especially the Double Ratchet code, which is original work, not a wrapped, battle-tested library.

## Known limitations

- No X3DH prekey infrastructure yet — see the Double Ratchet scope-cut note above.
- Cross-relay federation is client-side only right now (a client can reach a contact on a different relay by also connecting to it directly), not a real relay-to-relay protocol — two contacts who both use different custom relays (neither the default) can't yet reach each other.
- iOS has no push notifications when the app is fully closed (no Apple Developer account to issue an APNs key) — BLE mesh and web push both still work.
- This is a one-person project built in the open as it goes; some corners are more polished than others, and some features (noted in code comments) are deliberate scope-cuts, not oversights.

## Getting started

```bash
flutter pub get
flutter run
```

Requires the Flutter SDK (see `pubspec.yaml` for the minimum version) and, for calls, a TURN server — see [`relay_server/SELF_HOSTING.md`](relay_server/SELF_HOSTING.md) for running your own relay + TURN stack. Without `--dart-define`d TURN credentials, calls still work between peers that can connect directly (STUN-only).

## Repositories

| Repo | What it is |
|---|---|
| [Rlink](https://github.com/MihailKashintsev/Rlink) (this one) | The app — all client code |
| [rlink-relay](https://github.com/MihailKashintsev/rlink-relay) | The relay server (also vendored at `relay_server/` here) |
| [rlink-web](https://github.com/MihailKashintsev/rlink-web) | Mirror used for the GitHub Pages web build |
| [Rlink-releases](https://github.com/MihailKashintsev/Rlink-releases) | Signed release binaries, published by CI |

## License

GPL-3.0 — see [LICENSE](LICENSE).
