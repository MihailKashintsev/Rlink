import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Double Ratchet (Signal-style forward secrecy + post-compromise security)
/// on top of X25519 + ChaCha20-Poly1305 — the same primitives already used
/// by [CryptoService], just arranged into the ratchet's two nested KDF
/// chains instead of one fixed key.
///
/// **Scope cut, stated plainly**: real Signal sessions bootstrap via X3DH
/// (a signed prekey + a one-time prekey fetched from a server BEFORE the
/// first message, so the very first message is already forward-secret on
/// both sides). This module bootstraps the root key from a single X25519
/// ECDH between the two parties' long-term identity keys instead — there is
/// no prekey infrastructure in Rlink today, and building one is a separate,
/// larger piece of work (new relay endpoints to publish/fetch prekey
/// bundles, prekey rotation, etc.). The practical consequence: the very
/// first message in a new conversation has the same protection the current
/// scheme already provides (forward secrecy if the SENDER's long-term key
/// leaks, not if the RECEIVER's does); every message from the second
/// exchange onward gets full Double Ratchet protection on both sides, since
/// by then both parties have ratcheted at least once. This is a deliberate,
/// disclosed trade-off, not an oversight.
///
/// This file is the ratchet engine only — session persistence and wiring
/// into the actual send/receive pipeline (GossipRouter, capability
/// negotiation with peers not yet running this code) are separate, later
/// work. See double_ratchet_test.dart for the algorithm's correctness
/// proof: a full conversation, out-of-order delivery within a chain,
/// out-of-order delivery across a ratchet step, and the forged/tampered/
/// replayed negative cases.
class DoubleRatchet {
  DoubleRatchet._();

  static final _x25519 = X25519();
  static final _chacha = Chacha20.poly1305Aead();
  static const maxSkippedKeys = 1000;

  /// Bootstraps the session for whichever party sends the first message.
  /// [rootKeySeed] must be identical on both sides — e.g. an X25519 ECDH
  /// between the two parties' long-term identity keys, computed the same
  /// way [CryptoService.encryptMessage] already does today.
  /// [remoteInitialRatchetKey] is the other party's starting DH public key
  /// — in this scope-cut, their long-term X25519 identity public key (the
  /// same one already exchanged via profile broadcast).
  static Future<RatchetSession> initAsInitiator({
    required List<int> rootKeySeed,
    required SimplePublicKey remoteInitialRatchetKey,
  }) async {
    final dhSelf = await _x25519.newKeyPair();
    final dhOut = await _dh(dhSelf, remoteInitialRatchetKey);
    final (rk, sendCk) = await _kdfRk(rootKeySeed, dhOut);
    return RatchetSession._(
      dhSelf: dhSelf,
      dhRemote: remoteInitialRatchetKey,
      rootKey: rk,
      sendChainKey: sendCk,
    );
  }

  /// Bootstraps the session for whichever party is about to RECEIVE the
  /// first message. Has no chains yet — decrypting that first message
  /// triggers the initial DH ratchet step, which populates both.
  /// [selfInitialRatchetKeyPair] is this party's own long-term X25519
  /// identity keypair, reused as the starting ratchet keypair.
  static RatchetSession initAsResponder({
    required List<int> rootKeySeed,
    required SimpleKeyPair selfInitialRatchetKeyPair,
  }) {
    return RatchetSession._(
      dhSelf: selfInitialRatchetKeyPair,
      dhRemote: null,
      rootKey: Uint8List.fromList(rootKeySeed),
      sendChainKey: null,
    );
  }

  /// Encrypts [plaintext] and advances the sending chain by one step — the
  /// message key this produces is used exactly once and then unrecoverable
  /// from the session alone (forward secrecy within the chain).
  static Future<RatchetEnvelope> encrypt(
    RatchetSession session,
    List<int> plaintext,
  ) async {
    final sendChainKey = session.sendChainKey;
    if (sendChainKey == null) {
      throw StateError(
          'DoubleRatchet.encrypt: no sending chain yet — a responder session '
          'must receive at least one message before it can send');
    }
    final (messageKey, nextChainKey) = await _kdfCk(sendChainKey);
    final n = session._sendN;
    session.sendChainKey = nextChainKey;
    session._sendN++;

    final dhPub = await session.dhSelf.extractPublicKey();
    final nonce = _randomNonce();
    final box = await _chacha.encrypt(plaintext, secretKey: SecretKey(messageKey), nonce: nonce);
    return RatchetEnvelope(
      header: RatchetHeader(
        dhPublicKey: Uint8List.fromList(dhPub.bytes),
        n: n,
        pn: session._prevSendN,
      ),
      nonce: nonce,
      cipherText: box.cipherText,
      mac: box.mac.bytes,
    );
  }

  /// Decrypts [msg], performing a DH ratchet step first if it carries a new
  /// ratchet public key from the peer, and storing skipped-over message
  /// keys so an out-of-order message that arrives later can still decrypt.
  /// Returns null on any failure — wrong session, forged header, tampered
  /// ciphertext, or a message already consumed (replay) all fail this way,
  /// never by throwing into caller code that might mishandle it.
  static Future<List<int>?> decrypt(
    RatchetSession session,
    RatchetEnvelope msg,
  ) async {
    try {
      final skipId = _skipKeyId(msg.header.dhPublicKey, msg.header.n);
      final existingSkipped = session._skipped[skipId];
      if (existingSkipped != null) {
        final plain = await _tryDecryptWith(existingSkipped, msg);
        // Only consume the stored key once it's confirmed to actually work —
        // a forged message that happens to collide with a real skip-id must
        // not burn the legitimate key the real message still needs.
        if (plain != null) session._skipped.remove(skipId);
        return plain;
      }

      // Everything from here on is staged into local variables and only
      // written back onto `session` after the AEAD check at the very end
      // succeeds. A forged header (well-formed length, no real DH
      // relationship to the peer) is not guaranteed to make the DH ratchet
      // step itself throw — X25519 doesn't validate that a "public key" is a
      // real curve point — so if the ratchet step mutated `session` directly,
      // a forged message that gets correctly rejected at the final decrypt
      // would still have permanently desynced the session from the peer.
      var dhSelf = session.dhSelf;
      var dhRemote = session.dhRemote;
      var rootKey = session.rootKey;
      var sendChainKey = session.sendChainKey;
      var recvChainKey = session.recvChainKey;
      var sendN = session._sendN;
      var recvN = session._recvN;
      var prevSendN = session._prevSendN;
      final newSkipped = <String, Uint8List>{};

      final isNewRatchetKey =
          dhRemote == null || !_bytesEqual(dhRemote.bytes, msg.header.dhPublicKey);
      if (isNewRatchetKey) {
        if (recvChainKey != null && dhRemote != null) {
          final staged =
              await _stageSkippedKeys(recvChainKey, recvN, msg.header.pn, dhRemote.bytes);
          newSkipped.addAll(staged.$3);
        }

        final remotePub = SimplePublicKey(msg.header.dhPublicKey, type: KeyPairType.x25519);
        prevSendN = sendN;
        sendN = 0;
        recvN = 0;
        dhRemote = remotePub;

        final dhOut1 = await _dh(dhSelf, remotePub);
        final (rk1, newRecvCk) = await _kdfRk(rootKey, dhOut1);
        rootKey = rk1;
        recvChainKey = newRecvCk;

        dhSelf = await _x25519.newKeyPair();
        final dhOut2 = await _dh(dhSelf, remotePub);
        final (rk2, newSendCk) = await _kdfRk(rootKey, dhOut2);
        rootKey = rk2;
        sendChainKey = newSendCk;
      }

      if (recvChainKey == null) return null;
      final staged = await _stageSkippedKeys(recvChainKey, recvN, msg.header.n, msg.header.dhPublicKey);
      newSkipped.addAll(staged.$3);
      recvN = staged.$2;

      final (messageKey, nextChainKey) = await _kdfCk(staged.$1);
      final plain = await _tryDecryptWith(messageKey, msg);
      if (plain == null) return null; // AEAD failed — commit nothing.

      // Success — only now does any staged state touch the real session.
      session.dhSelf = dhSelf;
      session.dhRemote = dhRemote;
      session.rootKey = rootKey;
      session.sendChainKey = sendChainKey;
      session.recvChainKey = nextChainKey;
      session._sendN = sendN;
      session._recvN = recvN + 1;
      session._prevSendN = prevSendN;
      session._skipped.addAll(newSkipped);
      return plain;
    } catch (_) {
      // A forged header (garbage bytes as a "public key", an absurd n/pn)
      // must fail closed, not propagate as an exception the caller has to
      // remember to catch. Nothing above commits to `session` until the AEAD
      // check succeeds, so a caught exception also means `session` is
      // byte-for-byte unchanged from before this call.
      return null;
    }
  }

  /// Derives every not-yet-seen message key from [chainKey] up to (not
  /// including) [untilN] without touching any session state — the caller
  /// decides whether to commit the result. Bounded by [maxSkippedKeys]: a
  /// peer (or forged header) claiming an absurd message number is refused
  /// rather than spending unbounded CPU/memory chasing it.
  static Future<(Uint8List, int, Map<String, Uint8List>)> _stageSkippedKeys(
    Uint8List chainKey,
    int fromN,
    int untilN,
    List<int> dhLabel,
  ) async {
    if (untilN - fromN > maxSkippedKeys) {
      throw StateError('DoubleRatchet: refusing to skip ${untilN - fromN} keys');
    }
    var ck = chainKey;
    var n = fromN;
    final skipped = <String, Uint8List>{};
    while (n < untilN) {
      final (messageKey, nextChainKey) = await _kdfCk(ck);
      skipped[_skipKeyId(dhLabel, n)] = messageKey;
      ck = nextChainKey;
      n++;
    }
    return (ck, n, skipped);
  }

  static Future<List<int>?> _tryDecryptWith(
    Uint8List messageKey,
    RatchetEnvelope msg,
  ) async {
    try {
      final box = SecretBox(msg.cipherText, nonce: msg.nonce, mac: Mac(msg.mac));
      return await _chacha.decrypt(box, secretKey: SecretKey(messageKey));
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List> _dh(SimpleKeyPair kp, SimplePublicKey remote) async {
    final shared = await _x25519.sharedSecretKey(keyPair: kp, remotePublicKey: remote);
    return Uint8List.fromList(await shared.extractBytes());
  }

  /// KDF_RK — the root-chain KDF: mixes a new DH output into the current
  /// root key to derive both the next root key and a fresh chain key.
  static Future<(Uint8List, Uint8List)> _kdfRk(
    List<int> rootKey,
    List<int> dhOutput,
  ) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 64);
    final derived = await hkdf.deriveKey(secretKey: SecretKey(dhOutput), nonce: rootKey);
    final bytes = await derived.extractBytes();
    return (Uint8List.fromList(bytes.sublist(0, 32)), Uint8List.fromList(bytes.sublist(32, 64)));
  }

  /// KDF_CK — the symmetric-chain KDF: HMAC with two distinct constant
  /// inputs derives the one-time message key and the next chain key from
  /// the same chain key. One-way (HMAC), so possessing a chain key never
  /// reveals a message key already derived and discarded earlier — that's
  /// what makes forward secrecy hold WITHIN a chain, not just across a
  /// DH ratchet step.
  static Future<(Uint8List, Uint8List)> _kdfCk(List<int> chainKey) async {
    final hmac = Hmac.sha256();
    final messageKeyMac = await hmac.calculateMac(const [0x01], secretKey: SecretKey(chainKey));
    final nextChainMac = await hmac.calculateMac(const [0x02], secretKey: SecretKey(chainKey));
    return (Uint8List.fromList(messageKeyMac.bytes), Uint8List.fromList(nextChainMac.bytes));
  }

  static List<int> _randomNonce() {
    final rng = Random.secure();
    return List<int>.generate(12, (_) => rng.nextInt(256));
  }

  static String _skipKeyId(List<int> dhPub, int n) => '${base64Encode(dhPub)}:$n';

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Per-peer ratchet state. Mutates in place as messages are sent/received —
/// callers own persisting it (not done by this module; see the class doc).
class RatchetSession {
  SimpleKeyPair dhSelf;
  SimplePublicKey? dhRemote;
  Uint8List rootKey;
  Uint8List? sendChainKey;
  Uint8List? recvChainKey;
  int _sendN = 0;
  int _recvN = 0;
  int _prevSendN = 0;
  final Map<String, Uint8List> _skipped = {};

  RatchetSession._({
    required this.dhSelf,
    required this.dhRemote,
    required this.rootKey,
    required this.sendChainKey,
  });

  int get sendMessageNumber => _sendN;
  int get recvMessageNumber => _recvN;
  int get skippedKeyCount => _skipped.length;

  /// Serializes everything needed to resume this session later, including
  /// the raw private ratchet key — callers must store this exactly as
  /// securely as [CryptoService] stores the long-term identity keys.
  Future<Map<String, dynamic>> toJson() async {
    final selfPriv = await dhSelf.extractPrivateKeyBytes();
    final selfPub = await dhSelf.extractPublicKey();
    return {
      'dhSelfPriv': base64Encode(selfPriv),
      'dhSelfPub': base64Encode(selfPub.bytes),
      'dhRemote': dhRemote == null ? null : base64Encode(dhRemote!.bytes),
      'rootKey': base64Encode(rootKey),
      'sendChainKey': sendChainKey == null ? null : base64Encode(sendChainKey!),
      'recvChainKey': recvChainKey == null ? null : base64Encode(recvChainKey!),
      'sendN': _sendN,
      'recvN': _recvN,
      'prevSendN': _prevSendN,
      'skipped': _skipped.map((k, v) => MapEntry(k, base64Encode(v))),
    };
  }

  static RatchetSession fromJson(Map<String, dynamic> j) {
    final dhSelf = SimpleKeyPairData(
      base64Decode(j['dhSelfPriv'] as String),
      publicKey: SimplePublicKey(
        base64Decode(j['dhSelfPub'] as String),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );
    final dhRemoteB64 = j['dhRemote'] as String?;
    final session = RatchetSession._(
      dhSelf: dhSelf,
      dhRemote: dhRemoteB64 == null
          ? null
          : SimplePublicKey(base64Decode(dhRemoteB64), type: KeyPairType.x25519),
      rootKey: Uint8List.fromList(base64Decode(j['rootKey'] as String)),
      sendChainKey: (j['sendChainKey'] as String?) == null
          ? null
          : Uint8List.fromList(base64Decode(j['sendChainKey'] as String)),
    );
    session.recvChainKey = (j['recvChainKey'] as String?) == null
        ? null
        : Uint8List.fromList(base64Decode(j['recvChainKey'] as String));
    session._sendN = j['sendN'] as int;
    session._recvN = j['recvN'] as int;
    session._prevSendN = j['prevSendN'] as int;
    final skipped = (j['skipped'] as Map).cast<String, dynamic>();
    for (final entry in skipped.entries) {
      session._skipped[entry.key] = Uint8List.fromList(base64Decode(entry.value as String));
    }
    return session;
  }
}

class RatchetHeader {
  final Uint8List dhPublicKey;
  final int n;
  final int pn;

  const RatchetHeader({required this.dhPublicKey, required this.n, required this.pn});
}

class RatchetEnvelope {
  final RatchetHeader header;
  final List<int> nonce;
  final List<int> cipherText;
  final List<int> mac;

  const RatchetEnvelope({
    required this.header,
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });

  Map<String, dynamic> toJson() => {
        'dh': base64Encode(header.dhPublicKey),
        'n': header.n,
        'pn': header.pn,
        'nonce': base64Encode(nonce),
        'ct': base64Encode(cipherText),
        'mac': base64Encode(mac),
      };

  factory RatchetEnvelope.fromJson(Map<String, dynamic> j) => RatchetEnvelope(
        header: RatchetHeader(
          dhPublicKey: Uint8List.fromList(base64Decode(j['dh'] as String)),
          n: j['n'] as int,
          pn: j['pn'] as int,
        ),
        nonce: base64Decode(j['nonce'] as String),
        cipherText: base64Decode(j['ct'] as String),
        mac: base64Decode(j['mac'] as String),
      );
}
