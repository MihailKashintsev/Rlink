import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'runtime_platform.dart';
import 'web_account_bundle.dart';
import 'web_identity_portable.dart';

/// Хранит Ed25519 keypair пользователя (его "аккаунт") и отдельный X25519
/// keypair для ECDH шифрования сообщений.
///
/// Схема:
///   Identity  → Ed25519  (публичный ID пользователя)
///   X25519    → X25519   (ECDH key exchange per-message)
///   Payload   → ChaCha20-Poly1305 (AEAD шифрование)
class CryptoService {
  CryptoService._();
  static final CryptoService instance = CryptoService._();

  static const _keyPrivate = 'mesh_identity_private';
  static const _keyPublic = 'mesh_identity_public';
  static const _keyX25519Private = 'mesh_x25519_private';
  static const _keyX25519Public = 'mesh_x25519_public';

  // On desktop (macOS/Windows/Linux) Keychain/secure storage isn't reliable;
  // use SharedPreferences as fallback (keys are still generated fresh each time
  // on desktop and persisted across launches).
  static bool get _isMobile =>
      RuntimePlatform.isIos || RuntimePlatform.isAndroid;

  final _secureSt = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  Future<String?> _read(String key) async {
    if (RuntimePlatform.isWeb) {
      return WebAccountBundle.layeredRead(key);
    }
    if (_isMobile) return _secureSt.read(key: key);
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  Future<void> _write(String key, String value) async {
    if (RuntimePlatform.isWeb) {
      await WebAccountBundle.layeredWrite(key, value);
      return;
    }
    if (_isMobile) {
      await _secureSt.write(key: key, value: value);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    }
  }

  final _ed25519 = Ed25519();
  final _x25519 = X25519();
  final _chacha = Chacha20.poly1305Aead();

  late SimpleKeyPair _identityKeyPair;

  /// X25519 keypair для ECDH — хранится отдельно от Ed25519 идентити.
  /// Это обязательно: Ed25519 байты нельзя напрямую использовать как X25519.
  late SimpleKeyPair _x25519IdentityKeyPair;

  /// Публичный ключ как hex — это ID пользователя (аналог номера телефона)
  String publicKeyHex = '';

  /// X25519 публичный ключ в base64 — передаётся в profile broadcast
  /// и используется получателем для ECDH при шифровании сообщений.
  String x25519PublicKeyBase64 = '';

  /// Инициализация: загружаем или генерируем Ed25519 + X25519 keypairs
  Future<void> init() async {
    // ── Ed25519 identity keypair ──────────────────────────────────
    var restoredEd = false;
    var restoredX = false;

    if (!restoredEd) {
      try {
        final storedPrivate = await _read(_keyPrivate);
        final storedPublic = await _read(_keyPublic);
        if (storedPrivate != null &&
            storedPublic != null &&
            storedPrivate.isNotEmpty &&
            storedPublic.isNotEmpty) {
          final privateBytes = base64.decode(storedPrivate);
          final publicBytes = base64.decode(storedPublic);
          _identityKeyPair = SimpleKeyPairData(
            privateBytes,
            publicKey: SimplePublicKey(publicBytes, type: KeyPairType.ed25519),
            type: KeyPairType.ed25519,
          );
          restoredEd = true;
        }
      } catch (e) {
        debugPrint('[Crypto] Failed to restore Ed25519 keys, regenerating: $e');
      }
    }
    // Web: prefer discrete key slots (import) over bundle — stale bundle in one
    // backing store must not overwrite freshly imported keys in another.
    if (RuntimePlatform.isWeb && !restoredEd) {
      final bundle = await WebAccountBundle.loadValidatedBundleWithRetries();
      if (bundle != null) {
        try {
          final edPr = bundle['edPr'] as String;
          final edPu = bundle['edPu'] as String;
          final xPr = bundle['xPr'] as String;
          final xPu = bundle['xPu'] as String;
          _identityKeyPair = SimpleKeyPairData(
            base64.decode(edPr),
            publicKey:
                SimplePublicKey(base64.decode(edPu), type: KeyPairType.ed25519),
            type: KeyPairType.ed25519,
          );
          restoredEd = true;
          _x25519IdentityKeyPair = SimpleKeyPairData(
            base64.decode(xPr),
            publicKey:
                SimplePublicKey(base64.decode(xPu), type: KeyPairType.x25519),
            type: KeyPairType.x25519,
          );
          restoredX = true;
          await WebAccountBundle.layeredWrite(_keyPrivate, edPr);
          await WebAccountBundle.layeredWrite(_keyPublic, edPu);
          await WebAccountBundle.layeredWrite(_keyX25519Private, xPr);
          await WebAccountBundle.layeredWrite(_keyX25519Public, xPu);
        } catch (e) {
          debugPrint('[Crypto] Web bundle restore failed: $e');
          restoredEd = false;
          restoredX = false;
        }
      }
    }
    if (!restoredEd) {
      _identityKeyPair = await _ed25519.newKeyPair();
      final privateBytes = await _identityKeyPair.extractPrivateKeyBytes();
      final publicKey = await _identityKeyPair.extractPublicKey();
      await _write(_keyPrivate, base64.encode(privateBytes));
      await _write(_keyPublic, base64.encode(publicKey.bytes));
    }

    final pubKey = await _identityKeyPair.extractPublicKey();
    publicKeyHex = _bytesToHex(pubKey.bytes);

    // ── X25519 ECDH keypair ───────────────────────────────────────
    if (!restoredX) {
      try {
        final storedX25519Priv = await _read(_keyX25519Private);
        final storedX25519Pub = await _read(_keyX25519Public);
        if (storedX25519Priv != null &&
            storedX25519Pub != null &&
            storedX25519Priv.isNotEmpty &&
            storedX25519Pub.isNotEmpty) {
          final privBytes = base64.decode(storedX25519Priv);
          final pubBytes = base64.decode(storedX25519Pub);
          _x25519IdentityKeyPair = SimpleKeyPairData(
            privBytes,
            publicKey: SimplePublicKey(pubBytes, type: KeyPairType.x25519),
            type: KeyPairType.x25519,
          );
          restoredX = true;
        }
      } catch (e) {
        debugPrint('[Crypto] Failed to restore X25519 keys, regenerating: $e');
      }
    }
    if (RuntimePlatform.isWeb && !restoredX) {
      final bundle = await WebAccountBundle.loadValidatedBundleWithRetries();
      if (bundle != null) {
        try {
          final edPu = bundle['edPu'] as String?;
          if (edPu != null &&
              edPu.isNotEmpty &&
              _bytesToHex(base64.decode(edPu)) == publicKeyHex) {
            final xPr = bundle['xPr'] as String;
            final xPu = bundle['xPu'] as String;
            _x25519IdentityKeyPair = SimpleKeyPairData(
              base64.decode(xPr),
              publicKey:
                  SimplePublicKey(base64.decode(xPu), type: KeyPairType.x25519),
              type: KeyPairType.x25519,
            );
            restoredX = true;
            await WebAccountBundle.layeredWrite(_keyX25519Private, xPr);
            await WebAccountBundle.layeredWrite(_keyX25519Public, xPu);
          }
        } catch (e) {
          debugPrint('[Crypto] Web bundle X25519-only restore failed: $e');
        }
      }
    }
    if (!restoredX) {
      _x25519IdentityKeyPair = await _x25519.newKeyPair();
      final privBytes = await _x25519IdentityKeyPair.extractPrivateKeyBytes();
      final pubKeyX = await _x25519IdentityKeyPair.extractPublicKey();
      await _write(_keyX25519Private, base64.encode(privBytes));
      await _write(_keyX25519Public, base64.encode(pubKeyX.bytes));
    }

    final x25519PubKey = await _x25519IdentityKeyPair.extractPublicKey();
    x25519PublicKeyBase64 = base64.encode(x25519PubKey.bytes);

    if (RuntimePlatform.isWeb) {
      try {
        final edPrivBytes = await _identityKeyPair.extractPrivateKeyBytes();
        final edPubKey = await _identityKeyPair.extractPublicKey();
        final xPrivBytes =
            await _x25519IdentityKeyPair.extractPrivateKeyBytes();
        final xPubKey = await _x25519IdentityKeyPair.extractPublicKey();
        await WebAccountBundle.persistBundle(
          edPrivB64: base64.encode(edPrivBytes),
          edPubB64: base64.encode(edPubKey.bytes),
          xPrivB64: base64.encode(xPrivBytes),
          xPubB64: base64.encode(xPubKey.bytes),
          profileJson: null,
        );
        unawaited(WebIdentityPortable.syncIdentitySnapshotToOpfs());
      } catch (e) {
        debugPrint('[Crypto] Web account bundle persist failed: $e');
      }
    }
  }

  /// Force-generates brand-new Ed25519 + X25519 keypairs and persists them.
  /// Called during a full app reset so the new session uses a fresh identity
  /// immediately — without waiting for the next cold start.
  Future<void> regenerateKeys() async {
    // Ed25519 identity
    _identityKeyPair = await _ed25519.newKeyPair();
    final priv = await _identityKeyPair.extractPrivateKeyBytes();
    final pub = await _identityKeyPair.extractPublicKey();
    await _write(_keyPrivate, base64.encode(priv));
    await _write(_keyPublic, base64.encode(pub.bytes));
    publicKeyHex = _bytesToHex(pub.bytes);

    // X25519 ECDH
    _x25519IdentityKeyPair = await _x25519.newKeyPair();
    final xPriv = await _x25519IdentityKeyPair.extractPrivateKeyBytes();
    final xPub = await _x25519IdentityKeyPair.extractPublicKey();
    await _write(_keyX25519Private, base64.encode(xPriv));
    await _write(_keyX25519Public, base64.encode(xPub.bytes));
    x25519PublicKeyBase64 = base64.encode(xPub.bytes);

    if (RuntimePlatform.isWeb) {
      try {
        await WebAccountBundle.persistBundle(
          edPrivB64: base64.encode(priv),
          edPubB64: base64.encode(pub.bytes),
          xPrivB64: base64.encode(xPriv),
          xPubB64: base64.encode(xPub.bytes),
          profileJson: null,
        );
      } catch (e) {
        debugPrint('[Crypto] Web bundle persist after regenerate: $e');
      }
      unawaited(WebIdentityPortable.syncIdentitySnapshotToOpfs());
    }

    debugPrint('[Crypto] Keys regenerated → ${publicKeyHex.substring(0, 8)}…');
  }

  /// Raw key material for account transfer — the new device needs the
  /// actual private keys to legitimately become this account, not just the
  /// public identity. Callers MUST send this only through an encrypted
  /// channel (see `AccountTransferService`); nothing in this class does
  /// that encryption itself.
  Future<Map<String, String>> exportRawKeyMaterialForTransfer() async {
    final edPriv = await _identityKeyPair.extractPrivateKeyBytes();
    final edPub = await _identityKeyPair.extractPublicKey();
    final xPriv = await _x25519IdentityKeyPair.extractPrivateKeyBytes();
    final xPub = await _x25519IdentityKeyPair.extractPublicKey();
    return {
      'edPriv': base64.encode(edPriv),
      'edPub': base64.encode(edPub.bytes),
      'xPriv': base64.encode(xPriv),
      'xPub': base64.encode(xPub.bytes),
    };
  }

  /// Replaces this device's identity with received key material (account
  /// transfer). Unlike [regenerateKeys], this adopts a SPECIFIC keypair
  /// rather than generating a random one, and updates everything live —
  /// callers don't need to restart the app. The caller is responsible for
  /// verifying the material's provenance (signature + sender match) before
  /// calling this; this method trusts whatever bytes it's given.
  Future<void> restoreIdentity({
    required String edPrivB64,
    required String edPubB64,
    required String xPrivB64,
    required String xPubB64,
  }) async {
    final edPrivBytes = base64.decode(edPrivB64);
    final edPubBytes = base64.decode(edPubB64);
    final xPrivBytes = base64.decode(xPrivB64);
    final xPubBytes = base64.decode(xPubB64);

    _identityKeyPair = SimpleKeyPairData(
      edPrivBytes,
      publicKey: SimplePublicKey(edPubBytes, type: KeyPairType.ed25519),
      type: KeyPairType.ed25519,
    );
    _x25519IdentityKeyPair = SimpleKeyPairData(
      xPrivBytes,
      publicKey: SimplePublicKey(xPubBytes, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
    publicKeyHex = _bytesToHex(edPubBytes);
    x25519PublicKeyBase64 = base64.encode(xPubBytes);

    await _write(_keyPrivate, edPrivB64);
    await _write(_keyPublic, edPubB64);
    await _write(_keyX25519Private, xPrivB64);
    await _write(_keyX25519Public, xPubB64);

    if (RuntimePlatform.isWeb) {
      try {
        await WebAccountBundle.persistBundle(
          edPrivB64: edPrivB64,
          edPubB64: edPubB64,
          xPrivB64: xPrivB64,
          xPubB64: xPubB64,
          profileJson: null,
        );
        unawaited(WebIdentityPortable.syncIdentitySnapshotToOpfs());
      } catch (e) {
        debugPrint('[Crypto] Web bundle persist after restoreIdentity: $e');
      }
    }

    debugPrint(
        '[Crypto] Identity restored via account transfer → ${publicKeyHex.substring(0, 8)}…');
  }

  // ── Шифрование ───────────────────────────────────────────────

  /// Шифрует plaintext для получателя с его X25519 публичным ключом base64.
  Future<EncryptedMessage> encryptMessage({
    required String plaintext,
    required String recipientX25519KeyBase64,
  }) async {
    final recipientPubKeyBytes = base64.decode(recipientX25519KeyBase64);
    final recipientPubKey =
        SimplePublicKey(recipientPubKeyBytes, type: KeyPairType.x25519);

    // Ephemeral X25519 keypair для Forward Secrecy
    final ephemeralKeyPair = await _x25519.newKeyPair();
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: recipientPubKey,
    );
    final sharedSecretBytes = await sharedSecret.extractBytes();

    // Derive 32-byte key via simple SHA-256-like truncation
    final derivedKey = SecretKey(sharedSecretBytes.sublist(0, 32));

    // Cryptographically secure random nonce (12 bytes for ChaCha20-Poly1305)
    final rng = Random.secure();
    final nonce = List<int>.generate(12, (_) => rng.nextInt(256));
    final secretBox = await _chacha.encrypt(
      utf8.encode(plaintext),
      secretKey: derivedKey,
      nonce: nonce,
    );

    final ephemeralPubKey = await ephemeralKeyPair.extractPublicKey();

    final epkB64 = base64.encode(ephemeralPubKey.bytes);
    final nonceB64 = base64.encode(nonce);
    final ctB64 = base64.encode(secretBox.cipherText);
    final macB64 = base64.encode(secretBox.mac.bytes);

    // Authenticate the sender: sign the envelope with our Ed25519 identity key.
    // Without this the `from` field is an unverified claim and a malicious relay
    // could inject/spoof messages. Verified on receipt (verifyEncryptedEnvelope).
    final signature = await signUtf8Message(_envelopeSigningInput(
      senderPublicKey: publicKeyHex,
      ephemeralPublicKey: epkB64,
      nonce: nonceB64,
      cipherText: ctB64,
      mac: macB64,
    ));

    debugPrint(
        '[RLINK][Crypto] Encrypted message: ct=${secretBox.cipherText.length}b');

    return EncryptedMessage(
      senderPublicKey: publicKeyHex,
      ephemeralPublicKey: epkB64,
      nonce: nonceB64,
      cipherText: ctB64,
      mac: macB64,
      signature: signature,
    );
  }

  /// Canonical byte-string signed over the encrypted envelope. Identical on the
  /// sign (encrypt) and verify (receive) sides.
  static String _envelopeSigningInput({
    required String senderPublicKey,
    required String ephemeralPublicKey,
    required String nonce,
    required String cipherText,
    required String mac,
  }) =>
      'rlink.msg.v1|$senderPublicKey|$ephemeralPublicKey|$nonce|$cipherText|$mac';

  /// Verifies the Ed25519 signature over an [EncryptedMessage] against its
  /// claimed sender. Returns false for missing/invalid signatures — the DM
  /// inbound path drops anything that fails, closing sender-spoofing/injection.
  Future<bool> verifyEncryptedEnvelope(EncryptedMessage msg) async {
    if (msg.signature.isEmpty || msg.senderPublicKey.isEmpty) return false;
    try {
      final input = _envelopeSigningInput(
        senderPublicKey: msg.senderPublicKey,
        ephemeralPublicKey: msg.ephemeralPublicKey,
        nonce: msg.nonce,
        cipherText: msg.cipherText,
        mac: msg.mac,
      );
      final sigBytes = _hexToBytes(msg.signature);
      final pubBytes = _hexToBytes(msg.senderPublicKey);
      if (sigBytes.isEmpty || pubBytes.length != 32) return false;
      return await _ed25519.verify(
        utf8.encode(input),
        signature: Signature(
          sigBytes,
          publicKey: SimplePublicKey(pubBytes, type: KeyPairType.ed25519),
        ),
      );
    } catch (e) {
      debugPrint('[Crypto] verifyEncryptedEnvelope error: $e');
      return false;
    }
  }

  /// Verifies an Ed25519 signature over an arbitrary UTF-8 message against a
  /// claimed public key — the same primitive [verifyEncryptedEnvelope] uses
  /// internally, exposed directly for callers (account-transfer's
  /// proof-of-possession ack) that need to verify a signature that isn't
  /// wrapped in an [EncryptedMessage] envelope.
  Future<bool> verifyUtf8Signature(
      String pubHex, String message, String sigHex) async {
    try {
      final sigBytes = _hexToBytes(sigHex);
      final pubBytes = _hexToBytes(pubHex);
      if (sigBytes.isEmpty || pubBytes.length != 32) return false;
      return await _ed25519.verify(
        utf8.encode(message),
        signature: Signature(
          sigBytes,
          publicKey: SimplePublicKey(pubBytes, type: KeyPairType.ed25519),
        ),
      );
    } catch (e) {
      debugPrint('[Crypto] verifyUtf8Signature error: $e');
      return false;
    }
  }

  /// Safety number (like Signal's) — a stable 60-digit code both sides compute
  /// identically from the two identity (Ed25519) public keys. If two people read
  /// the same number aloud / scan the same QR, no relay has substituted keys.
  /// Deterministic regardless of who is "local": keys are ordered by hex.
  static Future<String> computeSafetyNumber(
      String keyHexA, String keyHexB) async {
    final a = _hexToBytes(keyHexA.trim().toLowerCase());
    final b = _hexToBytes(keyHexB.trim().toLowerCase());
    if (a.length != 32 || b.length != 32) return '';
    final ordered = keyHexA.toLowerCase().compareTo(keyHexB.toLowerCase()) <= 0
        ? <int>[...a, ...b]
        : <int>[...b, ...a];
    final input = <int>[...utf8.encode('rlink.safetynum.v1'), ...ordered];
    final digest = (await Sha512().hash(input)).bytes; // 64 bytes
    final sb = StringBuffer();
    for (var g = 0; g < 12; g++) {
      var v = 0;
      for (var i = 0; i < 5; i++) {
        v = (v * 256 + digest[g * 5 + i]) % 100000;
      }
      if (g > 0) sb.write(' ');
      sb.write(v.toString().padLeft(5, '0'));
    }
    return sb.toString();
  }

  /// Safety number between me and [remoteEd25519Hex].
  Future<String> safetyNumberWith(String remoteEd25519Hex) =>
      computeSafetyNumber(publicKeyHex, remoteEd25519Hex);

  static List<int> _hexToBytes(String hex) {
    final h = hex.trim();
    if (h.isEmpty || h.length.isOdd) return const [];
    final out = <int>[];
    for (var i = 0; i < h.length; i += 2) {
      final b = int.tryParse(h.substring(i, i + 2), radix: 16);
      if (b == null) return const [];
      out.add(b);
    }
    return out;
  }

  static const List<int> _mediaMagic = [0x52, 0x4C, 0x4D, 0x31]; // RLM1

  bool isSealedMediaPayload(Uint8List data) {
    return data.length > 4 + 1 + 32 + 12 + 16 &&
        data[0] == _mediaMagic[0] &&
        data[1] == _mediaMagic[1] &&
        data[2] == _mediaMagic[2] &&
        data[3] == _mediaMagic[3];
  }

  /// Шифрует произвольные байты медиа перед отправкой через relay/BLE.
  /// Формат бинарный: magic + epkLen + ephemeralPub + nonce + mac + ciphertext.
  Future<Uint8List> sealMediaPayload({
    required Uint8List plaintext,
    required String recipientX25519KeyBase64,
  }) async {
    final recipientPubKeyBytes = base64.decode(recipientX25519KeyBase64);
    final recipientPubKey =
        SimplePublicKey(recipientPubKeyBytes, type: KeyPairType.x25519);

    final ephemeralKeyPair = await _x25519.newKeyPair();
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: recipientPubKey,
    );
    final sharedSecretBytes = await sharedSecret.extractBytes();
    final derivedKey = SecretKey(sharedSecretBytes.sublist(0, 32));

    final rng = Random.secure();
    final nonce = Uint8List.fromList(
      List<int>.generate(12, (_) => rng.nextInt(256)),
    );
    final box = await _chacha.encrypt(
      plaintext,
      secretKey: derivedKey,
      nonce: nonce,
    );
    final ephemeralPubKey = await ephemeralKeyPair.extractPublicKey();
    final epk = Uint8List.fromList(ephemeralPubKey.bytes);
    if (epk.length > 255) {
      throw StateError('Unexpected media EPK length: ${epk.length}');
    }

    final out = BytesBuilder(copy: false)
      ..add(_mediaMagic)
      ..addByte(epk.length)
      ..add(epk)
      ..add(nonce)
      ..add(box.mac.bytes)
      ..add(box.cipherText);
    return out.toBytes();
  }

  /// Дешифрует media payload, созданный [sealMediaPayload].
  /// Возвращает null, если формат не наш или проверка AEAD не прошла.
  Future<Uint8List?> openMediaPayload(Uint8List sealed) async {
    if (!isSealedMediaPayload(sealed)) return null;
    try {
      final epkLen = sealed[4];
      const epkStart = 5;
      final epkEnd = epkStart + epkLen;
      final nonceStart = epkEnd;
      final nonceEnd = nonceStart + 12;
      final macStart = nonceEnd;
      final macEnd = macStart + 16;
      if (epkLen <= 0 || sealed.length <= macEnd) return null;

      final ephemeralPubKey = SimplePublicKey(
        sealed.sublist(epkStart, epkEnd),
        type: KeyPairType.x25519,
      );
      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: _x25519IdentityKeyPair,
        remotePublicKey: ephemeralPubKey,
      );
      final sharedSecretBytes = await sharedSecret.extractBytes();
      final derivedKey = SecretKey(sharedSecretBytes.sublist(0, 32));
      final box = SecretBox(
        sealed.sublist(macEnd),
        nonce: sealed.sublist(nonceStart, nonceEnd),
        mac: Mac(sealed.sublist(macStart, macEnd)),
      );
      final plain = await _chacha.decrypt(box, secretKey: derivedKey);
      return Uint8List.fromList(plain);
    } catch (e) {
      debugPrint('[RLINK][Crypto] Media decrypt failed: $e');
      return null;
    }
  }

  /// Дешифрует сообщение, зашифрованное для нас.
  /// Симметричное AEAD (ChaCha20-Poly1305) для бэкапа канала и др. локальных блобов.
  Future<Uint8List> sealSymmetric(Uint8List plain, List<int> key32) async {
    if (key32.length != 32) {
      throw ArgumentError.value(key32.length, 'key32', 'expected 32 bytes');
    }
    final rng = Random.secure();
    final nonce = List<int>.generate(12, (_) => rng.nextInt(256));
    final box = await _chacha.encrypt(
      plain,
      secretKey: SecretKey(key32),
      nonce: nonce,
    );
    return Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  Future<Uint8List?> openSymmetric(Uint8List sealed, List<int> key32) async {
    if (key32.length != 32 || sealed.length < 12 + 16) return null;
    final nonce = sealed.sublist(0, 12);
    final mac = Mac(sealed.sublist(sealed.length - 16));
    final ct = sealed.sublist(12, sealed.length - 16);
    try {
      final box = SecretBox(ct, nonce: nonce, mac: mac);
      final out = await _chacha.decrypt(box, secretKey: SecretKey(key32));
      return Uint8List.fromList(out);
    } catch (_) {
      return null;
    }
  }

  Future<String?> decryptMessage(EncryptedMessage msg) async {
    try {
      final ephemeralPubKeyBytes = base64.decode(msg.ephemeralPublicKey);
      final ephemeralPubKey =
          SimplePublicKey(ephemeralPubKeyBytes, type: KeyPairType.x25519);

      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: _x25519IdentityKeyPair,
        remotePublicKey: ephemeralPubKey,
      );
      final sharedSecretBytes = await sharedSecret.extractBytes();
      final derivedKey = SecretKey(sharedSecretBytes.sublist(0, 32));

      final nonce = base64.decode(msg.nonce);
      final cipherText = base64.decode(msg.cipherText);
      final mac = Mac(base64.decode(msg.mac));

      debugPrint('[RLINK][Crypto] Decrypt message: ct=${cipherText.length}b');

      final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);
      final plainBytes =
          await _chacha.decrypt(secretBox, secretKey: derivedKey);
      debugPrint('[RLINK][Crypto] Decrypt OK');
      return utf8.decode(plainBytes);
    } catch (e) {
      debugPrint('[RLINK][Crypto] Decrypt FAILED: $e');
      return null;
    }
  }

  /// Симметричное шифрование на ключе, выведенном из приватного Ed25519 (только эта идентичность).
  /// Уходит в сеть как opaque blob — relay не может извлечь хэш пароля админки.
  Future<String> sealAdminPanelSync(String plaintext) async {
    final key = await _adminPanelSyncSecretKey();
    final rng = Random.secure();
    final nonce = List<int>.generate(12, (_) => rng.nextInt(256));
    final box = await _chacha.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
    );
    return jsonEncode({
      'n': base64.encode(nonce),
      'ct': base64.encode(box.cipherText),
      'm': base64.encode(box.mac.bytes),
    });
  }

  Future<String?> openAdminPanelSync(String sealedJson) async {
    try {
      final j = jsonDecode(sealedJson) as Map<String, dynamic>;
      final n = j['n'] as String?;
      final ct = j['ct'] as String?;
      final m = j['m'] as String?;
      if (n == null || ct == null || m == null) return null;
      final nonce = base64.decode(n);
      final cipherText = base64.decode(ct);
      final mac = Mac(base64.decode(m));
      final key = await _adminPanelSyncSecretKey();
      final plain = await _chacha.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: key,
      );
      return utf8.decode(plain);
    } catch (e) {
      debugPrint('[Crypto] openAdminPanelSync failed: $e');
      return null;
    }
  }

  Future<SecretKey> _adminPanelSyncSecretKey() async {
    final priv = await _identityKeyPair.extractPrivateKeyBytes();
    final prefix = utf8.encode('rlink.admin_panel.sync.v1');
    final combined = <int>[...prefix, ...priv];
    final hash = await Sha256().hash(combined);
    return SecretKey(hash.bytes);
  }

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Ed25519-подпись UTF-8 строки (каталог публичных каналов на relay).
  Future<String> signUtf8Message(String message) async {
    final sig = await _ed25519.sign(
      utf8.encode(message),
      keyPair: _identityKeyPair,
    );
    return _bytesToHex(sig.bytes);
  }
}

class EncryptedMessage {
  final String senderPublicKey;
  final String ephemeralPublicKey;
  final String nonce;
  final String cipherText;
  final String mac;
  final String signature;

  const EncryptedMessage({
    required this.senderPublicKey,
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.cipherText,
    required this.mac,
    required this.signature,
  });

  Map<String, dynamic> toJson() => {
        'from': senderPublicKey,
        'epk': ephemeralPublicKey,
        'n': nonce,
        'ct': cipherText,
        'mac': mac,
        if (signature.isNotEmpty) 'sig': signature,
      };

  factory EncryptedMessage.fromJson(Map<String, dynamic> j) => EncryptedMessage(
        senderPublicKey: j['from'] as String? ?? '',
        ephemeralPublicKey: j['epk'] as String? ?? '',
        nonce: j['n'] as String? ?? '',
        cipherText: j['ct'] as String? ?? '',
        mac: j['mac'] as String? ?? '',
        signature: j['sig'] as String? ?? '',
      );
}
