# Idempotent in-place patch for the relay's server.dart (the host copy has diverged from git).
# Fixes the push burst: 747 web pushes in one minute for a single video-circle.
#  1. `_lastPushForRecipient` was set AFTER the awaited HTTP posts, so a burst of
#     packets all passed the 12 s cooldown check → mark it BEFORE sending.
#  2. A chunked media transfer is hundreds of `blob` messages → push only for the
#     first chunk and only once per msgId (a client resend repeats chunk 0).
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if '_shouldPushForBlob' in s:
    print('already patched'); sys.exit(0)

def rep(old, new):
    global s
    assert s.count(old) == 1, ('anchor count', s.count(old), old[:90])
    s = s.replace(old, new, 1)

# 1. Mark the cooldown before the first await. Works on both layouts of the
#    function (git copy and the older host copy): insert right after the
#    `subs` emptiness check inside _notifyRecipientQueued.
fn = s.index('Future<void> _notifyRecipientQueued({')
needle = "  if (subs == null || subs.isEmpty) return;\n"
at = s.index(needle, fn)
assert at - fn < 4000, 'unexpected layout'
s = s[:at + len(needle)] + """  // Mark NOW, before any await: otherwise a burst of queued packets all pass
  // the cooldown check above while the first push is still in flight.
  _lastPushForRecipient[recipientKey] = now;
""" + s[at + len(needle):]

rep("""Future<void> _notifyRecipientQueued({""", """/// Message ids of chunked `blob` transfers that already produced a push.
final Set<String> _pushedBlobMsgIds = <String>{};

/// A media transfer is hundreds of `blob` messages. Only its first chunk (and
/// only once per msgId — a client resend repeats chunk 0) may notify.
bool _shouldPushForBlob(Map<String, dynamic> msg, String relayMsgId) {
  final cIdx = msg['cIdx'];
  if (cIdx is int && cIdx != 0) return false;
  if (_pushedBlobMsgIds.length > 5000) _pushedBlobMsgIds.clear();
  return _pushedBlobMsgIds.add(relayMsgId);
}

Future<void> _notifyRecipientQueued({""")

rep("""  final recipient = _users[routeKey];
  if (recipient == null) {
    if (!noPush) {""", """  final recipient = _users[routeKey];
  if (recipient == null) {
    if (!noPush && _shouldPushForBlob(msg, relayMsgId)) {""")
open(p, 'w', encoding='utf-8').write(s)
print('patched')
