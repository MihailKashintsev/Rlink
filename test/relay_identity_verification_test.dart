import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Proves the relay's proof-of-possession fix against the REAL server
/// binary (not a mock): a client that signs the server's challenge nonce
/// registers "verified", and a second connection can no longer evict/
/// impersonate it just by claiming the same public key — only another
/// connection that also proves possession can. Before this fix, ANY client
/// could register as any publicKey with zero proof (see security-review,
/// 2026-08-27).
///
/// Talks raw WebSocket JSON directly (no RelayService/SecondaryRelayLink)
/// so the test exercises exactly the wire protocol, independent of either
/// client implementation.
void main() {
  late Process serverProcess;
  const port = 18100;
  const url = 'ws://localhost:$port';
  final repoRoot = Directory.current.path;

  setUpAll(() async {
    serverProcess = await Process.start(
      'dart',
      ['run', 'bin/server.dart'],
      environment: {'PORT': '$port'},
      workingDirectory: '$repoRoot/relay_server',
    );
    serverProcess.stderr.transform(const SystemEncoding().decoder).listen((l) {
      // ignore: avoid_print
      print('[relay stderr] $l');
    });
    await _waitUntilReady(port);
  });

  tearDownAll(() => serverProcess.kill());

  test('a valid proof registers as verified', () async {
    final identity = await _generateIdentity();
    final client = await _TestClient.connectAndRegister(url, identity,
        sign: true);
    addTearDown(client.close);
    expect(client.lastRegisteredOk, isTrue);
  });

  test('registering with no proof at all still works (legacy client)',
      () async {
    final identity = await _generateIdentity();
    final client = await _TestClient.connectAndRegister(url, identity,
        sign: false);
    addTearDown(client.close);
    expect(client.lastRegisteredOk, isTrue);
  });

  test(
      'an unsigned registration cannot evict an already-verified connection '
      'for the same key', () async {
    final identity = await _generateIdentity();
    final legit = await _TestClient.connectAndRegister(url, identity,
        sign: true);
    addTearDown(legit.close);
    expect(legit.lastRegisteredOk, isTrue);

    final impostor = await _TestClient.connectAndRegister(url, identity,
        sign: false);
    addTearDown(impostor.close);

    expect(impostor.lastRegisteredOk, isFalse,
        reason: 'impostor has no way to prove it holds the private key');
    expect(impostor.lastErrorMsg, 'identity_verification_required');

    // The legitimate connection must still be alive and untouched.
    await Future.delayed(const Duration(milliseconds: 300));
    expect(legit.isClosed, isFalse,
        reason: "a verified connection can't be silently evicted by an "
            'unverified claim to the same key');
  });

  test(
      'a correctly signed registration CAN take over from a previous '
      'verified connection (legitimate reconnect)', () async {
    final identity = await _generateIdentity();
    final first = await _TestClient.connectAndRegister(url, identity,
        sign: true);
    expect(first.lastRegisteredOk, isTrue);

    final second = await _TestClient.connectAndRegister(url, identity,
        sign: true);
    addTearDown(second.close);
    expect(second.lastRegisteredOk, isTrue);

    await Future.delayed(const Duration(milliseconds: 300));
    expect(first.isClosed, isTrue,
        reason: 'a real reconnect (valid proof) still evicts the old session');
  });

  test(
      'a forged proof does not grant verified status, so the real owner '
      'can still reclaim a squatted identity', () async {
    final victim = await _generateIdentity();
    final attacker = await _generateIdentity();

    // Attacker squats the never-before-seen identity, signing with their
    // OWN key while claiming the victim's publicKey. This still registers —
    // same as any legacy/unsigned first-contact would (no existing verified
    // session to protect yet) — but must NOT come out "verified".
    final squatter = _TestClient(url);
    addTearDown(squatter.close);
    await squatter.connect();
    await squatter.waitForChallenge();
    final forgedProof = await _sign(attacker, squatter.challengeNonce!);
    await squatter.sendRegister(victim.publicKeyHex, proof: forgedProof);
    await squatter.waitForRegisterOutcome();
    expect(squatter.lastRegisteredOk, isTrue);

    // The real victim connects later with a genuinely valid proof — must
    // still be able to reclaim the identity and evict the squatter, proving
    // the forged proof never actually verified.
    final real =
        await _TestClient.connectAndRegister(url, victim, sign: true);
    addTearDown(real.close);
    expect(real.lastRegisteredOk, isTrue);

    await Future.delayed(const Duration(milliseconds: 300));
    expect(squatter.isClosed, isTrue,
        reason: 'the real owner, proving actual possession, must be able '
            'to evict a squatter registered with a forged proof');
  });
}

class _Identity {
  final SimpleKeyPair keyPair;
  final String publicKeyHex;
  _Identity(this.keyPair, this.publicKeyHex);
}

Future<_Identity> _generateIdentity() async {
  final kp = await Ed25519().newKeyPair();
  final pub = await kp.extractPublicKey();
  final hex = pub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return _Identity(kp, hex);
}

Future<String> _sign(_Identity identity, String nonceHex) async {
  final sig = await Ed25519().sign(utf8.encode(nonceHex), keyPair: identity.keyPair);
  return sig.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class _TestClient {
  _TestClient(this.url);
  final String url;
  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  String? challengeNonce;
  bool? lastRegisteredOk;
  String? lastErrorMsg;
  bool isClosed = false;
  Completer<void>? _challengeCompleter;
  Completer<void>? _outcomeCompleter;

  Future<void> connect() async {
    final ws = WebSocketChannel.connect(Uri.parse(url));
    await ws.ready;
    _ws = ws;
    _sub = ws.stream.listen(_onMessage, onDone: () => isClosed = true);
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    final msg = jsonDecode(raw) as Map<String, dynamic>;
    switch (msg['type']) {
      case 'challenge':
        challengeNonce = msg['nonce'] as String?;
        _challengeCompleter?.complete();
        break;
      case 'registered':
        lastRegisteredOk = true;
        _outcomeCompleter?.complete();
        break;
      case 'error':
        lastRegisteredOk = false;
        lastErrorMsg = msg['msg'] as String?;
        _outcomeCompleter?.complete();
        break;
    }
  }

  Future<void> waitForChallenge() async {
    if (challengeNonce != null) return;
    _challengeCompleter = Completer<void>();
    await _challengeCompleter!.future.timeout(const Duration(seconds: 5));
  }

  Future<void> sendRegister(String publicKeyHex, {String? proof}) async {
    _outcomeCompleter = Completer<void>();
    _ws!.sink.add(jsonEncode({
      'type': 'register',
      'publicKey': publicKeyHex,
      'nick': 'test',
      if (proof != null) 'proof': proof,
    }));
  }

  Future<void> waitForRegisterOutcome() =>
      _outcomeCompleter!.future.timeout(const Duration(seconds: 5));

  static Future<_TestClient> connectAndRegister(
      String url, _Identity identity,
      {required bool sign}) async {
    final client = _TestClient(url);
    await client.connect();
    await client.waitForChallenge();
    final proof =
        sign ? await _sign(identity, client.challengeNonce!) : null;
    await client.sendRegister(identity.publicKeyHex, proof: proof);
    await client.waitForRegisterOutcome();
    return client;
  }

  Future<void> close() async {
    await _sub?.cancel();
    try {
      await _ws?.sink.close();
    } catch (_) {}
  }
}

Future<void> _waitUntilReady(int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final socket = await Socket.connect('localhost', port,
          timeout: const Duration(milliseconds: 500));
      await socket.close();
      return;
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }
  throw StateError('relay_server did not start listening on $port in time');
}
