# Idempotent in-place patch: /push/subscribe must prove ownership of the public
# key it subscribes for. The endpoint used to be stored for ANY 64-hex key with
# no proof, so an attacker could subscribe THEIR OWN push endpoint under a
# victim's key and receive every notification's metadata (who wrote, what kind)
# for as long as the row lived (max 8 rows per key — and they could also
# crowd out the real ones). Now the body must carry `ts` (ms, within 10 min)
# and `sig` = Ed25519(publicKey) over  rlink-push1|<publicKey>|<endpoint>|<ts>.
#
# Deploy AFTER the apps that sign (2.5.0+ web) are out: an unsigned subscribe
# is refused, so an old PWA can't re-register its push endpoint until it updates
# (existing subscriptions keep working).
import sys

p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'rlink-push1' in s:
    print('already patched')
    sys.exit(0)

old = """      if (!await _isSafePushEndpoint(endpoint)) {"""
assert s.count(old) == 1, 'anchor not found'
new = """      final tsRaw = decoded['ts'];
      final sigHex = (decoded['sig'] as String?)?.trim() ?? '';
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final signedOk = tsRaw is num &&
          (nowMs - tsRaw.toInt()).abs() <= 10 * 60 * 1000 &&
          sigHex.isNotEmpty &&
          await _verifyEd25519SignatureOnUtf8(
              'rlink-push1|$publicKey|$endpoint|${tsRaw.toInt()}',
              sigHex,
              publicKey);
      // Emergency switch only (env PUSH_ALLOW_UNSIGNED=1) if a client build
      // turns out unable to sign; the default is to require the proof.
      if (!signedOk && Platform.environment['PUSH_ALLOW_UNSIGNED'] != '1') {
        stdout.writeln('[RLINK][Relay] push/subscribe refused: bad/missing '
            'ownership signature for ${publicKey.substring(0, 8)}');
        return _jsonResponse({'ok': false, 'error': 'bad_signature'},
            status: 401);
      }
""" + old
s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8').write(s)
print('patched')
