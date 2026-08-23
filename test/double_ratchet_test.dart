import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/services/double_ratchet.dart';

void main() {
  final x25519 = X25519();

  Future<List<int>> sharedSecretBetween(SimpleKeyPair a, SimpleKeyPair b) async {
    final secret = await x25519.sharedSecretKey(
      keyPair: a,
      remotePublicKey: await b.extractPublicKey(),
    );
    return secret.extractBytes();
  }

  /// Sets up a fresh Alice/Bob pair the way real usage would: each has a
  /// long-term X25519 identity keypair (stand-in for CryptoService's), the
  /// root seed is their ECDH (exactly what CryptoService already computes
  /// today), Alice initiates, Bob responds.
  Future<(RatchetSession alice, RatchetSession bob)> freshPair() async {
    final aliceIdentity = await x25519.newKeyPair();
    final bobIdentity = await x25519.newKeyPair();
    final rootSeed = await sharedSecretBetween(aliceIdentity, bobIdentity);

    final alice = await DoubleRatchet.initAsInitiator(
      rootKeySeed: rootSeed,
      remoteInitialRatchetKey: await bobIdentity.extractPublicKey(),
    );
    final bob = DoubleRatchet.initAsResponder(
      rootKeySeed: rootSeed,
      selfInitialRatchetKeyPair: bobIdentity,
    );
    return (alice, bob);
  }

  group('basic conversation', () {
    test('single message: Alice → Bob', () async {
      final (alice, bob) = await freshPair();
      final env = await DoubleRatchet.encrypt(alice, utf8.encode('привет'));
      final plain = await DoubleRatchet.decrypt(bob, env);
      expect(plain, isNotNull);
      expect(utf8.decode(plain!), 'привет');
    });

    test('reply: Bob → Alice after receiving Alice\'s first message', () async {
      final (alice, bob) = await freshPair();
      final env1 = await DoubleRatchet.encrypt(alice, utf8.encode('hi'));
      await DoubleRatchet.decrypt(bob, env1);

      final env2 = await DoubleRatchet.encrypt(bob, utf8.encode('hello back'));
      final plain = await DoubleRatchet.decrypt(alice, env2);
      expect(plain, isNotNull);
      expect(utf8.decode(plain!), 'hello back');
    });

    test('a responder cannot send before receiving anything', () async {
      final (_, bob) = await freshPair();
      expect(
        () => DoubleRatchet.encrypt(bob, utf8.encode('too early')),
        throwsStateError,
      );
    });

    test('long back-and-forth conversation stays in sync', () async {
      final (alice, bob) = await freshPair();
      final transcript = <String>[];
      RatchetSession sender = alice, receiver = bob;
      for (var i = 0; i < 20; i++) {
        final text = 'message #$i from ${identical(sender, alice) ? "alice" : "bob"}';
        final env = await DoubleRatchet.encrypt(sender, utf8.encode(text));
        final plain = await DoubleRatchet.decrypt(receiver, env);
        expect(plain, isNotNull, reason: 'round $i failed to decrypt');
        transcript.add(utf8.decode(plain!));
        final tmp = sender;
        sender = receiver;
        receiver = tmp;
      }
      expect(transcript.length, 20);
      expect(transcript[0], 'message #0 from alice');
      expect(transcript[19], 'message #19 from bob');
    });

    test('several messages in a row without a reply all decrypt (chain advances)', () async {
      final (alice, bob) = await freshPair();
      final envs = [
        await DoubleRatchet.encrypt(alice, utf8.encode('one')),
        await DoubleRatchet.encrypt(alice, utf8.encode('two')),
        await DoubleRatchet.encrypt(alice, utf8.encode('three')),
      ];
      for (var i = 0; i < envs.length; i++) {
        final plain = await DoubleRatchet.decrypt(bob, envs[i]);
        expect(utf8.decode(plain!), ['one', 'two', 'three'][i]);
      }
    });
  });

  group('out-of-order delivery', () {
    test('messages arriving in reverse order within one chain all decrypt', () async {
      final (alice, bob) = await freshPair();
      final envs = [
        await DoubleRatchet.encrypt(alice, utf8.encode('a')),
        await DoubleRatchet.encrypt(alice, utf8.encode('b')),
        await DoubleRatchet.encrypt(alice, utf8.encode('c')),
      ];
      // Deliver c, then a, then b.
      expect(utf8.decode((await DoubleRatchet.decrypt(bob, envs[2]))!), 'c');
      expect(bob.skippedKeyCount, 2, reason: 'a and b were skipped over to reach c');
      expect(utf8.decode((await DoubleRatchet.decrypt(bob, envs[0]))!), 'a');
      expect(utf8.decode((await DoubleRatchet.decrypt(bob, envs[1]))!), 'b');
      expect(bob.skippedKeyCount, 0, reason: 'both skipped keys were consumed');
    });

    test('a message skipped across a DH ratchet step still decrypts when it arrives late', () async {
      final (alice, bob) = await freshPair();
      // Alice sends two messages on her first chain.
      final env1 = await DoubleRatchet.encrypt(alice, utf8.encode('first'));
      final env2 = await DoubleRatchet.encrypt(alice, utf8.encode('second — delayed'));
      // Bob only receives the first for now.
      await DoubleRatchet.decrypt(bob, env1);
      // Bob replies — this is a NEW ratchet key from Alice's point of view.
      final reply = await DoubleRatchet.encrypt(bob, utf8.encode('got your first one'));
      final replyPlain = await DoubleRatchet.decrypt(alice, reply);
      expect(utf8.decode(replyPlain!), 'got your first one');
      // Alice replies again — Bob will see a new ratchet key from Alice too,
      // needing to skip his old receiving chain up to `pn` first.
      final env3 = await DoubleRatchet.encrypt(alice, utf8.encode('third, after ratcheting'));
      final env3Plain = await DoubleRatchet.decrypt(bob, env3);
      expect(utf8.decode(env3Plain!), 'third, after ratcheting');
      // NOW the delayed second message from the OLD chain finally arrives.
      final env2Plain = await DoubleRatchet.decrypt(bob, env2);
      expect(env2Plain, isNotNull,
          reason: 'a message skipped before a ratchet step must still decrypt later');
      expect(utf8.decode(env2Plain!), 'second — delayed');
    });

    test('skip count beyond the safety cap is refused rather than hanging', () async {
      final (alice, bob) = await freshPair();
      // Send bob's chain forward one so he has a receiving chain to skip in.
      final env0 = await DoubleRatchet.encrypt(alice, utf8.encode('start'));
      await DoubleRatchet.decrypt(bob, env0);
      for (var i = 0; i < DoubleRatchet.maxSkippedKeys + 5; i++) {
        await DoubleRatchet.encrypt(alice, utf8.encode('$i'));
      }
      final farAhead = await DoubleRatchet.encrypt(alice, utf8.encode('far ahead'));
      final result = await DoubleRatchet.decrypt(bob, farAhead);
      expect(result, isNull, reason: 'must fail closed, not hang or throw uncaught');
    });
  });

  group('negative cases', () {
    test('a message from an unrelated session is rejected, not garbage-decrypted', () async {
      final (alice, bob) = await freshPair();
      final (mallory, _) = await freshPair(); // a totally different conversation
      final forged = await DoubleRatchet.encrypt(mallory, utf8.encode('trust me'));
      final result = await DoubleRatchet.decrypt(bob, forged);
      expect(result, isNull);
    });

    test('a tampered ciphertext fails AEAD and returns null', () async {
      final (alice, bob) = await freshPair();
      final env = await DoubleRatchet.encrypt(alice, utf8.encode('original'));
      final tamperedCt = Uint8List.fromList(env.cipherText);
      tamperedCt[0] ^= 0xFF;
      final tampered = RatchetEnvelope(
        header: env.header,
        nonce: env.nonce,
        cipherText: tamperedCt,
        mac: env.mac,
      );
      expect(await DoubleRatchet.decrypt(bob, tampered), isNull);
    });

    test('a tampered header dhPublicKey is rejected rather than corrupting session state', () async {
      final (alice, bob) = await freshPair();
      final env = await DoubleRatchet.encrypt(alice, utf8.encode('hi'));
      final forgedHeader = RatchetHeader(
        dhPublicKey: Uint8List.fromList(List.filled(32, 0xAB)), // not a real curve point necessarily, but well-formed length
        n: env.header.n,
        pn: env.header.pn,
      );
      final forged = RatchetEnvelope(
        header: forgedHeader,
        nonce: env.nonce,
        cipherText: env.cipherText,
        mac: env.mac,
      );
      final result = await DoubleRatchet.decrypt(bob, forged);
      expect(result, isNull);
      // The real message must still decrypt afterwards — a rejected forgery
      // must not have mutated bob's session into a broken state.
      expect(utf8.decode((await DoubleRatchet.decrypt(bob, env))!), 'hi');
    });

    test('replaying an already-consumed (non-skipped) message fails, not double-decrypts', () async {
      final (alice, bob) = await freshPair();
      final env = await DoubleRatchet.encrypt(alice, utf8.encode('once'));
      final first = await DoubleRatchet.decrypt(bob, env);
      expect(first, isNotNull);
      final replay = await DoubleRatchet.decrypt(bob, env);
      expect(replay, isNull, reason: 'the chain already advanced past this message');
    });

    test('replaying an already-consumed skipped message fails the second time', () async {
      final (alice, bob) = await freshPair();
      final env1 = await DoubleRatchet.encrypt(alice, utf8.encode('a'));
      final env2 = await DoubleRatchet.encrypt(alice, utf8.encode('b'));
      await DoubleRatchet.decrypt(bob, env2); // skips env1's key
      final firstDecrypt = await DoubleRatchet.decrypt(bob, env1);
      expect(firstDecrypt, isNotNull);
      final secondDecrypt = await DoubleRatchet.decrypt(bob, env1);
      expect(secondDecrypt, isNull, reason: 'the skipped key was consumed and removed on first use');
    });

    test('garbage bytes as ciphertext/mac never throw out of decrypt()', () async {
      final (_, bob) = await freshPair();
      final garbage = RatchetEnvelope(
        header: RatchetHeader(dhPublicKey: Uint8List(32), n: 0, pn: 0),
        nonce: List.filled(12, 1),
        cipherText: List.filled(5, 2),
        mac: List.filled(16, 3),
      );
      expect(await DoubleRatchet.decrypt(bob, garbage), isNull);
    });
  });

  group('forward secrecy properties', () {
    test('chain keys advance one-way: the session never exposes a way back to an earlier message key', () async {
      final (alice, bob) = await freshPair();
      final env1 = await DoubleRatchet.encrypt(alice, utf8.encode('secret one'));
      await DoubleRatchet.decrypt(bob, env1);
      final chainKeyAfterFirst = bob.recvChainKey == null ? null : Uint8List.fromList(bob.recvChainKey!);

      final env2 = await DoubleRatchet.encrypt(alice, utf8.encode('secret two'));
      await DoubleRatchet.decrypt(bob, env2);

      // The chain key genuinely changed (KDF_CK actually advanced state).
      expect(bob.recvChainKey, isNot(equals(chainKeyAfterFirst)));
      // And env1 cannot be decrypted again from bob's now-advanced session —
      // its message key existed only transiently inside the KDF_CK call.
      expect(await DoubleRatchet.decrypt(bob, env1), isNull);
    });

    test('a DH ratchet step changes the root key so old root key material cannot derive new chains', () async {
      final (alice, bob) = await freshPair();
      final env1 = await DoubleRatchet.encrypt(alice, utf8.encode('before ratchet'));
      await DoubleRatchet.decrypt(bob, env1);
      final rootBefore = Uint8List.fromList(bob.rootKey);

      final reply = await DoubleRatchet.encrypt(bob, utf8.encode('reply'));
      await DoubleRatchet.decrypt(alice, reply);
      final env2 = await DoubleRatchet.encrypt(alice, utf8.encode('after ratchet'));
      await DoubleRatchet.decrypt(bob, env2);

      expect(bob.rootKey, isNot(equals(rootBefore)));
    });
  });

  group('serialization', () {
    test('a session round-trips through toJson/fromJson and keeps working', () async {
      final (alice, bob) = await freshPair();
      final env1 = await DoubleRatchet.encrypt(alice, utf8.encode('before save'));
      await DoubleRatchet.decrypt(bob, env1);

      final json = await bob.toJson();
      final reencoded = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
      final restoredBob = RatchetSession.fromJson(reencoded);

      final reply = await DoubleRatchet.encrypt(alice, utf8.encode('after save'));
      final plain = await DoubleRatchet.decrypt(restoredBob, reply);
      expect(plain, isNotNull);
      expect(utf8.decode(plain!), 'after save');
    });

    test('skipped keys survive a save/restore round-trip', () async {
      final (alice, bob) = await freshPair();
      final env1 = await DoubleRatchet.encrypt(alice, utf8.encode('a'));
      final env2 = await DoubleRatchet.encrypt(alice, utf8.encode('b'));
      await DoubleRatchet.decrypt(bob, env2); // env1's key gets skipped+stored
      expect(bob.skippedKeyCount, 1);

      final restored = RatchetSession.fromJson(await bob.toJson());
      expect(restored.skippedKeyCount, 1);
      final plain = await DoubleRatchet.decrypt(restored, env1);
      expect(plain, isNotNull);
      expect(utf8.decode(plain!), 'a');
    });
  });
}
