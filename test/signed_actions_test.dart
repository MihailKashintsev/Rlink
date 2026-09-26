import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:rlink/services/channel_service.dart';
import 'package:rlink/services/crypto_service.dart';
import 'package:rlink/services/signed_action.dart';
import 'package:rlink/utils/edit_delete_seal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
}

/// Makes the process-wide CryptoService adopt a brand-new identity and returns
/// (publicKeyHex, x25519PublicKeyBase64).
Future<(String, String)> becomeNewIdentity() async {
  final ed = await Ed25519().newKeyPair();
  final x = await X25519().newKeyPair();
  final xPub = base64Encode((await x.extractPublicKey()).bytes);
  await CryptoService.instance.restoreIdentity(
    edPrivB64: base64Encode(await ed.extractPrivateKeyBytes()),
    edPubB64: base64Encode((await ed.extractPublicKey()).bytes),
    xPrivB64: base64Encode(await x.extractPrivateKeyBytes()),
    xPubB64: xPub,
  );
  return (CryptoService.instance.publicKeyHex, xPub);
}

/// What actually crosses the wire: JSON encode + decode.
Map<String, dynamic> wire(Map<String, dynamic> m) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(m)) as Map);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

  group('SignedAction', () {
    test('a signed payload verifies to its signer after a wire round trip',
        () async {
      final (a, _) = await becomeNewIdentity();
      final p = wire(await SignedAction.sign('channel_block', {
        'channelId': 'c1',
        'value': true,
        'by': 'whatever-the-packet-claims',
      }));
      expect(await SignedAction.verify('channel_block', p), a);
    });

    test('any change to the payload, a different kind, or a re-labelled signer '
        'invalidates it', () async {
      await becomeNewIdentity();
      final p = wire(await SignedAction.sign('group_update', {
        'groupId': 'g1',
        'memberIds': ['a', 'b'],
        'moderatorIds': ['a'],
      }));
      expect(await SignedAction.verify('group_update', p), isNotNull);

      final promoted = Map<String, dynamic>.from(p)
        ..['moderatorIds'] = ['a', 'attacker'];
      expect(await SignedAction.verify('group_update', promoted), isNull);

      expect(await SignedAction.verify('channel_meta', p), isNull,
          reason: 'signature is bound to the packet kind');

      final (attacker, _) = await becomeNewIdentity();
      final relabelled = Map<String, dynamic>.from(p)..['sk'] = attacker;
      expect(await SignedAction.verify('group_update', relabelled), isNull,
          reason: 'claiming someone else as signer must not verify');

      final unsigned = Map<String, dynamic>.from(p)
        ..remove('sg')
        ..remove('sk');
      expect(await SignedAction.verify('group_update', unsigned), isNull);
    });

    test('the same action re-signed by another identity reports THAT signer',
        () async {
      final (owner, _) = await becomeNewIdentity();
      final body = {'channelId': 'c1', 'value': true};
      final byOwner = wire(await SignedAction.sign('channel_block', body));
      expect(await SignedAction.verify('channel_block', byOwner), owner);
      final (other, _) = await becomeNewIdentity();
      final byOther = wire(await SignedAction.sign('channel_block', body));
      expect(await SignedAction.verify('channel_block', byOther), other);
      expect(other, isNot(owner));
    });

    test('replay guard: only strictly newer timestamps are accepted', () async {
      const key = 'meta:replay-test';
      expect(await SignedAction.acceptNewer(key, 1000), isTrue);
      expect(await SignedAction.acceptNewer(key, 1000), isFalse);
      expect(await SignedAction.acceptNewer(key, 999), isFalse);
      expect(await SignedAction.acceptNewer(key, 1001), isTrue);
      expect(
          await SignedAction.acceptNewer(
              'meta:future', DateTime.now().millisecondsSinceEpoch + 3 * 86400000),
          isFalse,
          reason: 'a far-future timestamp would freeze the key');
    });
  });

  group('DM edit/delete envelope', () {
    test('signed + sealed edit round-trips; the message id is bound inside',
        () async {
      final (sender, _) = await becomeNewIdentity();
      // Receiver identity's X25519 key.
      final rxEd = await Ed25519().newKeyPair();
      final rxX = await X25519().newKeyPair();
      final rxXPub = base64Encode((await rxX.extractPublicKey()).bytes);

      final env = await CryptoService.instance.encryptMessage(
        plaintext: sealEditDeletePlain('msg-1', 1000, 'new text'),
        recipientX25519KeyBase64: rxXPub,
      );
      expect(env.senderPublicKey, sender);
      expect(await CryptoService.instance.verifyEncryptedEnvelope(env), isTrue);

      // Receiver adopts its identity and opens the envelope.
      await CryptoService.instance.restoreIdentity(
        edPrivB64: base64Encode(await rxEd.extractPrivateKeyBytes()),
        edPubB64: base64Encode((await rxEd.extractPublicKey()).bytes),
        xPrivB64: base64Encode(await rxX.extractPrivateKeyBytes()),
        xPubB64: rxXPub,
      );
      final plain = await CryptoService.instance.decryptMessage(env);
      expect(plain, isNotNull);
      expect(openEditDeletePlain(plain!, 'msg-1'), ('new text', 1000));
      // The same valid envelope re-sent for another message id is refused.
      expect(openEditDeletePlain(plain, 'msg-2'), isNull);
    });

    test('a delete carries no text and a forged claimed sender fails the '
        'signature check', () async {
      await becomeNewIdentity();
      final rx = await X25519().newKeyPair();
      final rxXPub = base64Encode((await rx.extractPublicKey()).bytes);
      final env = await CryptoService.instance.encryptMessage(
        plaintext: sealEditDeletePlain('msg-9', 2000),
        recipientX25519KeyBase64: rxXPub,
      );
      expect(await CryptoService.instance.verifyEncryptedEnvelope(env), isTrue);
      expect(openEditDeletePlain(sealEditDeletePlain('msg-9', 2000), 'msg-9'),
          ('', 2000));

      // Attacker claims to be the victim: swap in another sender key.
      final victim = await Ed25519().newKeyPair();
      final victimHex = (await victim.extractPublicKey())
          .bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final forged = EncryptedMessage.fromJson({...env.toJson(), 'from': victimHex});
      expect(
          await CryptoService.instance.verifyEncryptedEnvelope(forged), isFalse);
    });
  });

  group('DM edit/delete authorization (main.dart onEdit/onDelete logic)', () {
    test('a contact cannot edit or delete a message I actually sent', () {
      // existing.isOutgoing == true: I sent it. Ordinary text is not exempt.
      expect(
          editDeleteAllowedForMessage(
              existingIsOutgoing: true, isMerge: false),
          isFalse,
          reason: 'this was the bug: onEdit never checked isOutgoing at all');
      // onDelete never has a merge exception, even hypothetically.
      expect(
          editDeleteAllowedForMessage(existingIsOutgoing: true, isMerge: true),
          isTrue,
          reason: 'isMerge:true is only ever passed by onEdit for a shared '
              'todo/calendar payload, never by onDelete');
    });

    test('a contact can edit/delete a message THEY sent', () {
      expect(
          editDeleteAllowedForMessage(
              existingIsOutgoing: false, isMerge: false),
          isTrue);
    });

    test('shared todo/calendar state is the one deliberate exception', () {
      expect(
          editDeleteAllowedForMessage(existingIsOutgoing: true, isMerge: true),
          isTrue);
    });

    test('replaying an old, validly-signed edit cannot roll a message back '
        'to an earlier text', () async {
      const key = 'edit:msg-rollback';
      // The newer edit (ts=200) lands first...
      expect(await SignedAction.acceptNewer(key, 200), isTrue);
      // ...then an OLDER captured envelope (ts=150, e.g. relayed late or
      // replayed by whoever could see the ciphertext in transit) must not
      // be able to revert it.
      expect(await SignedAction.acceptNewer(key, 150), isFalse);
      // The exact same edit replayed again is also rejected (not just older).
      expect(await SignedAction.acceptNewer(key, 200), isFalse);
      // A genuinely newer edit still goes through.
      expect(await SignedAction.acceptNewer(key, 201), isTrue);
    });

    test('a captured delete cannot undo an edit that happened after it', () async {
      // onEdit and onDelete share the 'edit:$messageId' timeline on purpose.
      const key = 'edit:msg-shared-timeline';
      expect(await SignedAction.acceptNewer(key, 500), isTrue); // an edit
      expect(await SignedAction.acceptNewer(key, 300), isFalse); // stale delete
    });
  });

  group('channel meta acceptance (real ChannelService + sqlite)', () {
    late Directory tmp;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      tmp = await Directory.systemTemp.createTemp('rlink_sig_test_');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
      await ChannelService.instance.init();
    });

    tearDownAll(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    /// Router-equivalent: verify, then hand the handler the verified signer.
    Future<void> deliver(Map<String, dynamic> packet) async {
      final p = wire(packet);
      p.remove('_signer');
      final signer = await SignedAction.verify('channel_meta', p);
      await ChannelService.instance
          .applyChannelMetaFromPayload(p, signer: signer);
    }

    Future<Map<String, dynamic>> metaBy(String adminId,
        {List<String> mods = const [],
        String name = 'News',
        bool verified = false}) async {
      return SignedAction.sign('channel_meta', {
        'channelId': 'chan-1',
        'name': name,
        'adminId': adminId,
        'subscriberIds': [adminId],
        'moderatorIds': mods,
        'verified': verified,
      });
    }

    test('only the owner\'s signature can create, then change, a channel',
        () async {
      final (owner, _) = await becomeNewIdentity();
      await deliver(await metaBy(owner, mods: ['mod-1'], verified: true));

      var ch = await ChannelService.instance.getChannel('chan-1');
      expect(ch, isNotNull);
      expect(ch!.adminId, owner);
      expect(ch.moderatorIds, ['mod-1']);
      expect(ch.verified, isFalse,
          reason: 'a channel must not verify itself through gossip');

      // The owner id is public: an attacker names the owner but signs with
      // their own key and puts themselves in the moderator list.
      final (attacker, _) = await becomeNewIdentity();
      await deliver(await metaBy(owner, mods: [attacker], name: 'HACKED'));
      ch = await ChannelService.instance.getChannel('chan-1');
      expect(ch!.moderatorIds, ['mod-1']);
      expect(ch.name, 'News');

      // Unsigned (what every old client sends) is ignored too.
      final unsigned = wire(await metaBy(owner, mods: [attacker]))
        ..remove('sg')
        ..remove('sk');
      await deliver(unsigned);
      ch = await ChannelService.instance.getChannel('chan-1');
      expect(ch!.moderatorIds, ['mod-1']);
    });

    test('a genuinely newer owner update applies; replaying an OLD signed '
        'packet does not undo it', () async {
      // Re-adopt the owner: the previous test left the attacker's identity active.
      final ownerRow = (await ChannelService.instance.getChannel('chan-1'))!;
      // Build the owner's signing identity again by generating a fresh channel
      // owner for this test (channel-2), to keep the test self-contained.
      final (owner2, _) = await becomeNewIdentity();
      Future<Map<String, dynamic>> meta2(List<String> mods, int sts) async {
        final m = await SignedAction.sign('channel_meta', {
          'channelId': 'chan-2',
          'name': 'Two',
          'adminId': owner2,
          'moderatorIds': mods,
        });
        // sign() stamps "now"; pin the time so the ordering is deterministic.
        final body = Map<String, dynamic>.from(m)..remove('sg');
        body['sts'] = sts;
        final sig = await CryptoService.instance.signUtf8Message(
            'rlink-act1|channel_meta|${SignedAction.canonical(body)}');
        return {...body, 'sg': sig};
      }

      final base = DateTime.now().millisecondsSinceEpoch - 100000;
      final v1 = await meta2(['m1', 'm2'], base + 1);
      final v2 = await meta2(['m1'], base + 2); // m2 was demoted
      await deliver(v1);
      await deliver(v2);
      var ch = await ChannelService.instance.getChannel('chan-2');
      expect(ch!.moderatorIds, ['m1']);

      // Attacker/relay re-sends the old, validly signed packet.
      await deliver(v1);
      ch = await ChannelService.instance.getChannel('chan-2');
      expect(ch!.moderatorIds, ['m1'], reason: 'replay must not resurrect m2');
      expect(ownerRow.id, 'chan-1');
    });

    test('relay-directory entries (server-verified) still carry the flags',
        () async {
      final (owner3, _) = await becomeNewIdentity();
      await ChannelService.instance.applyChannelMetaFromPayload({
        'channelId': 'chan-3',
        'name': 'Dir',
        'adminId': owner3,
        'verified': true,
        'verifiedBy': 'relay',
      }, trusted: true);
      final ch = await ChannelService.instance.getChannel('chan-3');
      expect(ch!.verified, isTrue);
    });
  });
}
