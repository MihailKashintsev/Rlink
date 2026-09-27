import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';
import 'package:rlink/models/bot_blueprint.dart';
import 'package:rlink/services/bot_code_generator.dart';
import 'package:rlink/services/crypto_service.dart';
import 'package:rlink/services/double_ratchet.dart';
import 'package:rlink/services/image_service.dart';
import 'package:rlink/utils/bounded_gzip.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression tests for the 2026-09 red-team findings that are pure logic
/// (each one reproduced the attack before the fix).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  // CryptoService picks a storage backend by platform; force desktop so it
  // takes the SharedPreferences path instead of needing a real secure-storage
  // plugin (see test/signed_actions_test.dart for the same setup).
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

  group('received file names can never leave their folder', () {
    const dir = '/Users/victim/Documents/files';
    for (final attack in [
      '../../pwned.txt',
      '/etc/passwd',
      '../../../../Library/LaunchAgents/evil.plist',
      '..\\..\\evil.txt',
      '....//....//etc//passwd',
      '',
      '...',
    ]) {
      test('"$attack"', () {
        final safe = ImageService.sanitizeStoredName(attack);
        expect(safe, isNotEmpty);
        expect(p.isWithin(dir, p.join(dir, safe)), isTrue,
            reason: 'joined path escaped: ${p.join(dir, safe)}');
      });
    }

    test('an ordinary name is kept', () {
      expect(ImageService.sanitizeStoredName('report Q3.pdf'), 'report Q3.pdf');
    });

    test('the sticker-pack download path (missed in the first sweep) stays put',
        () {
      const dir = '/Users/victim/Documents/images';
      // Mirrors StickerPackDmService.receiveFromRelay's destName construction.
      for (final msgId in [
        '../../../../Library/LaunchAgents/evil',
        'stickerpack_../../../../etc/passwd',
      ]) {
        final destName =
            ImageService.sanitizeStoredName('stk_downloaded_${msgId}_0.png');
        expect(p.isWithin(dir, p.join(dir, destName)), isTrue,
            reason: 'joined path escaped: ${p.join(dir, destName)}');
      }
    });
  });

  group('boundedGunzip', () {
    test('a valid small gzip decodes', () {
      final gz = GZipEncoder().encode(utf8.encode('{"fmt":"x"}'));
      expect(utf8.decode(boundedGunzip(gz)!), '{"fmt":"x"}');
    });

    test('a gzip bomb over the decompressed cap is refused', () {
      // 8 MB of zeros compresses to a few KB; cap it at 1 MB.
      final bomb = GZipEncoder().encode(Uint8List(8 * 1024 * 1024));
      expect(bomb.length, lessThan(64 * 1024));
      expect(boundedGunzip(bomb, maxDecompressedBytes: 1024 * 1024), isNull);
    });

    test('oversized compressed input and garbage are refused', () {
      expect(boundedGunzip(Uint8List(2048), maxCompressedBytes: 1024), isNull);
      expect(boundedGunzip(utf8.encode('not gzip at all')), isNull);
    });
  });

  test('a bot name cannot inject code into the generated Python', () async {
    final bp = BotBlueprint(
      id: 'b1',
      name: 'x"); __import__(\'os\').system(\'touch /tmp/rlink_injected\'); print("',
      handle: 'evilbot',
    );
    final code = BotCodeGenerator.python(bp);
    final tmp = await Directory.systemTemp.createTemp('rlink_bot_');
    final f = File(p.join(tmp.path, 'bot.py'))..writeAsStringSync(code);
    // Must still be syntactically valid Python whose only effect of the name is
    // being text (ast.parse would fail if the quote had been closed early).
    final r = await Process.run('python3', [
      '-c',
      'import ast,sys; t=ast.parse(open(sys.argv[1]).read()); '
          'bad=[n for n in ast.walk(t) if isinstance(n, ast.Call) and getattr(n.func,"id","")=="__import__"]; '
          'sys.exit(1 if bad else 0)',
      f.path,
    ]);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    await tmp.delete(recursive: true);
  });

  test('the ratchet cannot be made to keep unbounded skipped keys', () async {
    final x = X25519();
    final a = await x.newKeyPair();
    final b = await x.newKeyPair();
    final shared = await x.sharedSecretKey(
        keyPair: a, remotePublicKey: await b.extractPublicKey());
    final seed = await shared.extractBytes();
    final attacker = await DoubleRatchet.initAsInitiator(
      rootKeySeed: seed,
      remoteInitialRatchetKey: await b.extractPublicKey(),
    );
    final victim = DoubleRatchet.initAsResponder(
      rootKeySeed: seed,
      selfInitialRatchetKeyPair: b,
    );
    // Each round the attacker skips ~999 messages (under the per-step cap).
    for (var round = 0; round < 5; round++) {
      for (var i = 0; i < 999; i++) {
        await DoubleRatchet.encrypt(attacker, utf8.encode('x'));
      }
      final last = await DoubleRatchet.encrypt(attacker, utf8.encode('y'));
      expect(await DoubleRatchet.decrypt(victim, last), isNotNull);
      expect(victim.skippedKeyCount,
          lessThanOrEqualTo(DoubleRatchet.maxTotalSkippedKeys));
    }
    expect(victim.skippedKeyCount, DoubleRatchet.maxTotalSkippedKeys);
  });

  group('account backup file encryption (same primitives as AccountTransferService)',
      () {
    // Mirrors exactly what exportAccountToFile/importAccountFromFile do:
    // Argon2id(password, salt) -> 32-byte key -> ChaCha20-Poly1305 AEAD via
    // CryptoService.sealSymmetric/openSymmetric. The methods themselves are
    // instance methods entangled with the whole app's storage services, so
    // this exercises the actual security-critical primitive directly rather
    // than standing up that whole stack.
    Future<Uint8List> deriveKey(String password, Uint8List salt) async {
      final algo = Argon2id(
          parallelism: 1, memory: 19456, iterations: 2, hashLength: 32);
      final key =
          await algo.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
      return Uint8List.fromList(await key.extractBytes());
    }

    test('the right password round-trips the plaintext', () async {
      final salt = Uint8List.fromList(List.generate(16, (i) => i));
      final key = await deriveKey('correct horse battery staple', salt);
      final plain = utf8.encode(jsonEncode({'keys': 'super-secret'}));
      final sealed =
          await CryptoService.instance.sealSymmetric(Uint8List.fromList(plain), key);
      final opened = await CryptoService.instance.openSymmetric(sealed, key);
      expect(opened, isNotNull);
      expect(utf8.decode(opened!), jsonEncode({'keys': 'super-secret'}));
    });

    test('a wrong password fails closed instead of returning garbage',
        () async {
      final salt = Uint8List.fromList(List.generate(16, (i) => i));
      final rightKey = await deriveKey('correct horse battery staple', salt);
      final wrongKey = await deriveKey('a guess', salt);
      final sealed = await CryptoService.instance
          .sealSymmetric(Uint8List.fromList(utf8.encode('identity keys')), rightKey);
      expect(await CryptoService.instance.openSymmetric(sealed, wrongKey), isNull);
      // Same password, different salt (as a fresh export would use) also fails
      // — the salt must travel with the file and be used verbatim.
      final otherSalt = Uint8List.fromList(List.generate(16, (i) => i + 1));
      final keyWithOtherSalt =
          await deriveKey('correct horse battery staple', otherSalt);
      expect(
          await CryptoService.instance.openSymmetric(sealed, keyWithOtherSalt),
          isNull);
    });

    test('a single flipped byte anywhere in the sealed file is rejected',
        () async {
      final salt = Uint8List.fromList(List.generate(16, (i) => i));
      final key = await deriveKey('correct horse battery staple', salt);
      final sealed = await CryptoService.instance.sealSymmetric(
          Uint8List.fromList(utf8.encode('a fairly long identity payload')),
          key);
      for (final i in [0, sealed.length ~/ 2, sealed.length - 1]) {
        final tampered = Uint8List.fromList(sealed);
        tampered[i] ^= 0xFF;
        expect(await CryptoService.instance.openSymmetric(tampered, key), isNull,
            reason: 'flipping byte $i must invalidate the AEAD tag');
      }
    });
  });
}
