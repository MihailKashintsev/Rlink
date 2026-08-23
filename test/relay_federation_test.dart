import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/services/gossip_router.dart';
import 'package:rlink/services/secondary_relay_link.dart';

/// Proves [SecondaryRelayLink] actually speaks the relay's real wire
/// protocol — not a mock of it — by running the actual `relay_server`
/// binary as a subprocess and exchanging a packet through it. This is the
/// closest thing to a live two-device test available in this environment:
/// no real BLE/second machine, but a real server process, not an assumption
/// about what it does.
///
/// Deliberately does NOT exercise `RelayService._syncSecondaryLink()`'s own
/// orchestration (when to create/tear down the link) — `defaultServerUrl`
/// is a compile-time const there, not injectable, so that branching logic
/// is covered by direct code reading instead. What matters most — does a
/// packet sent from one identity actually arrive at another identity
/// registered on the same server, decoded correctly — is covered here.
void main() {
  late Process serverProcess;
  const port = 18099;
  const url = 'ws://localhost:$port';
  final repoRoot = Directory.current.path;

  setUpAll(() async {
    serverProcess = await Process.start(
      'dart',
      ['run', 'bin/server.dart'],
      environment: {'PORT': '$port'},
      workingDirectory: '$repoRoot/relay_server',
    );
    // Surface server-side failures instead of just timing out silently.
    serverProcess.stderr.transform(const SystemEncoding().decoder).listen((l) {
      // ignore: avoid_print
      print('[relay stderr] $l');
    });
    await _waitUntilReady(port);
  });

  tearDownAll(() {
    serverProcess.kill();
  });

  test(
      'two SecondaryRelayLinks against a real relay_server exchange a directed packet',
      () async {
    final keyA = ('a' * 64);
    final keyB = ('b' * 64);

    String? receivedFrom;
    int? receivedActivity;
    final router = GossipRouter.instance;
    router.myPublicKey = keyB;
    router.onTypingReceived = (from, activity) {
      receivedFrom = from;
      receivedActivity = activity;
    };
    addTearDown(() {
      router.onTypingReceived = null;
      router.myPublicKey = null;
    });

    final linkA = SecondaryRelayLink(
      url: url,
      myPublicKey: () => keyA,
      myNick: () => 'A',
      myX25519: () => '',
    );
    final linkB = SecondaryRelayLink(
      url: url,
      myPublicKey: () => keyB,
      myNick: () => 'B',
      myX25519: () => '',
    );
    addTearDown(() {
      linkA.dispose();
      linkB.dispose();
    });

    await linkA.connect();
    await linkB.connect();
    await _waitUntil(() => linkA.isReady && linkB.isReady,
        timeout: const Duration(seconds: 10));

    final packet = GossipPacket(
      id: 'federation-test-1',
      type: 'typing',
      ttl: 2,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'from': keyA,
        'a': 1,
        'r': keyB.substring(0, 8),
      },
    );
    await linkA.send(packet, recipientKey: keyB);

    await _waitUntil(() => receivedFrom != null,
        timeout: const Duration(seconds: 10));
    expect(receivedFrom, keyA);
    expect(receivedActivity, 1);
  }, timeout: const Timeout(Duration(seconds: 30)));
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

Future<void> _waitUntil(bool Function() condition,
    {required Duration timeout}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('condition not met within $timeout');
}
