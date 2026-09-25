# Idempotent in-place patch for the relay's server.dart (the host copy has
# diverged from git — see deploy/patch_push_burst.py / patch_webpush.py for the
# same pattern). Closes the "phase 1" findings from the 2026-09-25 red-team
# pass that don't require any client/protocol change:
#  1. mailbox: byte caps (per-recipient + global), not just a count cap —
#     `blob` could grow it unboundedly (verified: 224 MB in ~2 s).
#  2. `blob` had NO rate limit at all (excluded from the flood check because a
#     real transfer is legitimately many small messages) — add a byte-based one.
#  3. admin-hash brute force: no throttle on any of the 5 admin_* handlers
#     (measured 3500+ guesses/s) — shared per-connection attempt limiter.
#  4. push/subscribe SSRF: the relay itself later POSTs to the stored
#     `endpoint` with a signed VAPID header — verified exploitable against
#     127.0.0.1. Now requires a resolvable public HTTPS host (blocks
#     loopback/private/link-local ranges) + a per-IP rate limit.
#  5. mailbox delivery/ack hijack: registering under someone else's key needed
#     no proof at all when that key has no LIVE verified session (an ordinary
#     offline user) — verified: steal + delete their queued mail. Now requires
#     the existing proof-of-possession ("verified") flag, which every client
#     since the 2026-08-27 fix already sends.
#  6. /health leaked nick + short key + connect time of every online user to
#     anyone, unauthenticated — gated behind an opt-in operator header token.
#  7. the block list only ever filtered presence broadcasts; search and direct
#     packet/blob delivery ignored it — a blocked sender could still find and
#     message their target. Now enforced in all three.
import sys

p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if '_isBlockedByRecipient' in s:
    print('already patched')
    sys.exit(0)


def rep(old, new, cnt=1):
    global s
    n = s.count(old)
    assert n == cnt, (n, cnt, old[:90])
    s = s.replace(old, new, cnt)


# 1. mailbox byte caps
rep(
    "final Map<String, Map<String, Map<String, dynamic>>> _mailbox = {};\n"
    "const _mailboxFile = 'relay_mailbox.json';\n"
    "const _mailboxMaxPerRecipient = 600;\n"
    "Timer? _mailboxPersistTimer;",
    "final Map<String, Map<String, Map<String, dynamic>>> _mailbox = {};\n"
    "const _mailboxFile = 'relay_mailbox.json';\n"
    "const _mailboxMaxPerRecipient = 600;\n"
    "const _mailboxMaxBytesPerRecipient = 20 * 1024 * 1024;\n"
    "const _mailboxMaxTotalBytes = 150 * 1024 * 1024;\n"
    "int _mailboxTotalBytes = 0;\n"
    "Timer? _mailboxPersistTimer;\n\n"
    "int _envelopeApproxBytes(Map<String, dynamic> envelope) =>\n"
    "    (envelope['data'] as String?)?.length ?? 64;\n\n"
    "int _bucketBytes(Map<String, Map<String, dynamic>> bucket) =>\n"
    "    bucket.values.fold(0, (a, e) => a + _envelopeApproxBytes(e));",
)

rep(
    "  final key = recipientKey.toLowerCase();\n"
    "  final bucket =\n"
    "      _mailbox.putIfAbsent(key, () => <String, Map<String, dynamic>>{});\n"
    "  bucket[relayMsgId] = envelope;\n"
    "  while (bucket.length > _mailboxMaxPerRecipient) {\n"
    "    bucket.remove(bucket.keys.first);\n"
    "  }\n"
    "  _persistMailbox();\n"
    "}",
    "  final key = recipientKey.toLowerCase();\n"
    "  final bucket =\n"
    "      _mailbox.putIfAbsent(key, () => <String, Map<String, dynamic>>{});\n"
    "  bucket[relayMsgId] = envelope;\n"
    "  _mailboxTotalBytes += _envelopeApproxBytes(envelope);\n"
    "  while (bucket.length > _mailboxMaxPerRecipient ||\n"
    "      _bucketBytes(bucket) > _mailboxMaxBytesPerRecipient) {\n"
    "    final oldestId = bucket.keys.first;\n"
    "    _mailboxTotalBytes -= _envelopeApproxBytes(bucket.remove(oldestId)!);\n"
    "  }\n"
    "  while (_mailboxTotalBytes > _mailboxMaxTotalBytes && _mailbox.isNotEmpty) {\n"
    "    final k = _mailbox.keys\n"
    "        .firstWhere((k) => _mailbox[k]!.isNotEmpty, orElse: () => '');\n"
    "    if (k.isEmpty) break;\n"
    "    final b = _mailbox[k]!;\n"
    "    _mailboxTotalBytes -= _envelopeApproxBytes(b.remove(b.keys.first)!);\n"
    "    if (b.isEmpty) _mailbox.remove(k);\n"
    "  }\n"
    "  _persistMailbox();\n"
    "}",
)

rep(
    "void _ackRecipientMessage(String recipientKey, String relayMsgId) {\n"
    "  final bucket = _mailbox[recipientKey.toLowerCase()];\n"
    "  if (bucket == null) return;\n"
    "  bucket.remove(relayMsgId);\n"
    "  if (bucket.isEmpty) _mailbox.remove(recipientKey.toLowerCase());\n"
    "  _persistMailbox();\n"
    "}",
    "void _ackRecipientMessage(String recipientKey, String relayMsgId) {\n"
    "  final bucket = _mailbox[recipientKey.toLowerCase()];\n"
    "  if (bucket == null) return;\n"
    "  final removed = bucket.remove(relayMsgId);\n"
    "  if (removed != null) _mailboxTotalBytes -= _envelopeApproxBytes(removed);\n"
    "  if (bucket.isEmpty) _mailbox.remove(recipientKey.toLowerCase());\n"
    "  _persistMailbox();\n"
    "}",
)

# recompute the byte total after loading the persisted mailbox on startup
fn = s.index('void _loadMailbox(')
needle = "if (byId.isNotEmpty) _mailbox[recipient.toLowerCase()] = byId;\n    });\n"
at = s.index(needle, fn)
tail_needle = "stdout.writeln(\n        '[RLINK][Relay] Loaded mailbox for ${_mailbox.length} recipients');"
tend = s.index(tail_needle, at)
s = (
    s[:at + len(needle)]
    + "    _mailboxTotalBytes = _mailbox.values.fold(0, (a, b) => a + _bucketBytes(b));\n    "
    + "stdout.writeln('[RLINK][Relay] Loaded mailbox for ${_mailbox.length} '\n        'recipients (~${_mailboxTotalBytes ~/ 1024} KB)');"
    + s[tend + len(tail_needle):]
)

# 2. blob byte-rate limiter
rep(
    "bool _checkRate(String publicKey) {\n"
    "  final now = DateTime.now();\n"
    "  final times = _rateLimits.putIfAbsent(publicKey, () => []);\n"
    "  times.removeWhere((t) => now.difference(t) > _rateWindow);\n"
    "  if (times.length >= _rateMax) return false; // rate limited\n"
    "  times.add(now);\n"
    "  return true;\n"
    "}",
    "bool _checkRate(String publicKey) {\n"
    "  final now = DateTime.now();\n"
    "  final times = _rateLimits.putIfAbsent(publicKey, () => []);\n"
    "  times.removeWhere((t) => now.difference(t) > _rateWindow);\n"
    "  if (times.length >= _rateMax) return false; // rate limited\n"
    "  times.add(now);\n"
    "  return true;\n"
    "}\n\n"
    "const _blobByteWindow = Duration(seconds: 10);\n"
    "const _blobByteMax = 30 * 1024 * 1024;\n"
    "final Map<String, List<(DateTime, int)>> _blobByteLimits = {};\n\n"
    "bool _checkBlobByteRate(String publicKey, int bytes) {\n"
    "  final now = DateTime.now();\n"
    "  final entries = _blobByteLimits.putIfAbsent(publicKey, () => []);\n"
    "  entries.removeWhere((e) => now.difference(e.$1) > _blobByteWindow);\n"
    "  final total = entries.fold(0, (a, e) => a + e.$2) + bytes;\n"
    "  if (total > _blobByteMax) return false;\n"
    "  entries.add((now, bytes));\n"
    "  return true;\n"
    "}",
)

rep(
    "  final type = msg['type'] as String?;\n"
    "  if (type == null) return;\n\n"
    "  if (_isBotBlockedOrRevoked(user.publicKey) && type != 'ping') {",
    "  final type = msg['type'] as String?;\n"
    "  if (type == null) return;\n\n"
    "  if (type == 'blob' && !_checkBlobByteRate(user.publicKey, raw.length)) {\n"
    "    user.ws.sink.add(jsonEncode({'type': 'error', 'msg': 'rate_limited'}));\n"
    "    return;\n"
    "  }\n\n"
    "  if (_isBotBlockedOrRevoked(user.publicKey) && type != 'ping') {",
)

# 3. admin brute-force throttle
def_idx = s.index('bool _isAdminHashValid(')
end_idx = s.index('\n}\n', def_idx) + 3
admin_helper = (
    "\nconst _adminAuthWindow = Duration(minutes: 1);\n"
    "const _adminAuthMax = 10;\n"
    "final Map<String, List<DateTime>> _adminAuthAttempts = {};\n\n"
    "bool _checkAdminAuthRate(String key) {\n"
    "  final now = DateTime.now();\n"
    "  final times = _adminAuthAttempts.putIfAbsent(key, () => []);\n"
    "  times.removeWhere((t) => now.difference(t) > _adminAuthWindow);\n"
    "  if (times.length >= _adminAuthMax) return false;\n"
    "  times.add(now);\n"
    "  return true;\n"
    "}\n"
)
s = s[:end_idx] + admin_helper + s[end_idx:]

rep(
    "  if (!_isAdminHashValid(_jsonString(msg['adminHash']))) {\n"
    "    ack({'ok': false, 'error': 'forbidden'});\n"
    "    return;\n"
    "  }",
    "  if (!_checkAdminAuthRate(user.publicKey) ||\n"
    "      !_isAdminHashValid(_jsonString(msg['adminHash']))) {\n"
    "    ack({'ok': false, 'error': 'forbidden'});\n"
    "    return;\n"
    "  }",
    2,
)
rep(
    "  if (!_isAdminHashValid(oldHash)) {\n"
    "    ack({'ok': false, 'error': 'forbidden'});\n"
    "    return;\n"
    "  }",
    "  if (!_checkAdminAuthRate(user.publicKey) || !_isAdminHashValid(oldHash)) {\n"
    "    ack({'ok': false, 'error': 'forbidden'});\n"
    "    return;\n"
    "  }",
    1,
)
rep(
    "  if (!_isAdminHashValid(adminHash)) {\n"
    "    ack({'ok': false, 'error': 'forbidden'});\n"
    "    return;\n"
    "  }",
    "  if (!_checkAdminAuthRate(user.publicKey) || !_isAdminHashValid(adminHash)) {\n"
    "    ack({'ok': false, 'error': 'forbidden'});\n"
    "    return;\n"
    "  }",
    2,
)

# 4. push/subscribe SSRF + rate-limit
marker = "void _upsertPushSubscription(String recipientKey, Map<String, dynamic> sub) {"
assert s.count(marker) == 1
push_helper = (
    "const _pushSubscribeWindow = Duration(minutes: 1);\n"
    "const _pushSubscribeMax = 20;\n"
    "final Map<String, List<DateTime>> _pushSubscribeRateLimits = {};\n\n"
    "bool _checkPushSubscribeRate(String ip) {\n"
    "  final now = DateTime.now();\n"
    "  final times = _pushSubscribeRateLimits.putIfAbsent(ip, () => []);\n"
    "  times.removeWhere((t) => now.difference(t) > _pushSubscribeWindow);\n"
    "  if (times.length >= _pushSubscribeMax) return false;\n"
    "  times.add(now);\n"
    "  return true;\n"
    "}\n\n"
    "String _clientIp(shelf.Request request) {\n"
    "  final fwd = request.headers['x-forwarded-for'];\n"
    "  if (fwd != null && fwd.isNotEmpty) return fwd.split(',').first.trim();\n"
    "  final ci = request.context['shelf.io.connection_info'];\n"
    "  if (ci is HttpConnectionInfo) return ci.remoteAddress.address;\n"
    "  return 'unknown';\n"
    "}\n\n"
    "bool _isPrivateOrLocalAddress(InternetAddress a) {\n"
    "  if (a.isLoopback || a.isLinkLocal || a.isMulticast) return true;\n"
    "  final h = a.address;\n"
    "  if (a.type == InternetAddressType.IPv4) {\n"
    "    if (h.startsWith('10.') ||\n"
    "        h.startsWith('192.168.') ||\n"
    "        h == '169.254.169.254') {\n"
    "      return true;\n"
    "    }\n"
    "    if (h.startsWith('172.')) {\n"
    "      final second = int.tryParse(h.split('.').elementAtOrNull(1) ?? '') ?? 0;\n"
    "      if (second >= 16 && second <= 31) return true;\n"
    "    }\n"
    "    if (h == '0.0.0.0') return true;\n"
    "  } else {\n"
    "    if (h.startsWith('fc') || h.startsWith('fd')) return true;\n"
    "    if (h == '::1' || h == '::') return true;\n"
    "  }\n"
    "  return false;\n"
    "}\n\n"
    "Future<bool> _isSafePushEndpoint(String endpoint) async {\n"
    "  Uri uri;\n"
    "  try {\n"
    "    uri = Uri.parse(endpoint);\n"
    "  } catch (_) {\n"
    "    return false;\n"
    "  }\n"
    "  if (uri.scheme != 'https' || uri.host.isEmpty) return false;\n"
    "  try {\n"
    "    final addrs = await InternetAddress.lookup(uri.host)\n"
    "        .timeout(const Duration(seconds: 3));\n"
    "    if (addrs.isEmpty) return false;\n"
    "    return addrs.every((a) => !_isPrivateOrLocalAddress(a));\n"
    "  } catch (_) {\n"
    "    return false;\n"
    "  }\n"
    "}\n\n"
) + marker
s = s.replace(marker, push_helper, 1)

rep(
    "  if (request.url.path == 'push/subscribe' && request.method == 'POST') {\n"
    "    if (!_webPushConfigured) {\n"
    "      return _jsonResponse({'ok': false, 'error': 'push_not_configured'},\n"
    "          status: 503);\n"
    "    }\n"
    "    try {",
    "  if (request.url.path == 'push/subscribe' && request.method == 'POST') {\n"
    "    if (!_webPushConfigured) {\n"
    "      return _jsonResponse({'ok': false, 'error': 'push_not_configured'},\n"
    "          status: 503);\n"
    "    }\n"
    "    if (!_checkPushSubscribeRate(_clientIp(request))) {\n"
    "      return _jsonResponse({'ok': false, 'error': 'rate_limited'}, status: 429);\n"
    "    }\n"
    "    try {",
)

rep(
    "      final endpoint = (subRaw['endpoint'] as String?)?.trim() ?? '';\n"
    "      final keysRaw = subRaw['keys'];\n"
    "      if (endpoint.isEmpty || keysRaw is! Map) {\n"
    "        return _jsonResponse({'ok': false, 'error': 'bad_subscription'},\n"
    "            status: 400);\n"
    "      }",
    "      final endpoint = (subRaw['endpoint'] as String?)?.trim() ?? '';\n"
    "      final keysRaw = subRaw['keys'];\n"
    "      if (endpoint.isEmpty || keysRaw is! Map) {\n"
    "        return _jsonResponse({'ok': false, 'error': 'bad_subscription'},\n"
    "            status: 400);\n"
    "      }\n"
    "      if (!await _isSafePushEndpoint(endpoint)) {\n"
    "        return _jsonResponse({'ok': false, 'error': 'unsafe_endpoint'},\n"
    "            status: 400);\n"
    "      }",
)

# 5. mailbox proof-of-possession requirement
rep(
    "void _sendMailboxSnapshot(_User user) {\n"
    "  final bucket = _mailbox[user.publicKey];\n"
    "  if (bucket == null || bucket.isEmpty) return;",
    "void _sendMailboxSnapshot(_User user) {\n"
    "  if (!user.verified) return;\n"
    "  final bucket = _mailbox[user.publicKey];\n"
    "  if (bucket == null || bucket.isEmpty) return;",
)
rep(
    "void _handleRelayAck(_User user, Map<String, dynamic> msg) {\n"
    "  final relayMsgId = msg['msgId'] as String?;\n"
    "  if (relayMsgId == null || relayMsgId.isEmpty) return;\n"
    "  _ackRecipientMessage(user.publicKey, relayMsgId);\n"
    "}",
    "void _handleRelayAck(_User user, Map<String, dynamic> msg) {\n"
    "  if (!user.verified) return;\n"
    "  final relayMsgId = msg['msgId'] as String?;\n"
    "  if (relayMsgId == null || relayMsgId.isEmpty) return;\n"
    "  _ackRecipientMessage(user.publicKey, relayMsgId);\n"
    "}",
)

# 6. /health: gate the peer list behind an operator token
old_health = (
    "  if (request.url.path == 'health') {\n"
    "    final peers = _users.values\n"
    "        .map((u) => {\n"
    "              'shortId': u.shortId,\n"
    "              'nick': u.nick,\n"
    "              'connectedAt': u.connectedAt.toIso8601String(),\n"
    "            })\n"
    "        .toList();\n"
    "    return _jsonResponse({\n"
    "      'status': 'ok',\n"
    "      'online': _users.length,\n"
    "      'peers': peers,\n"
    "      'uptime': DateTime.now().toIso8601String(),\n"
    "      'pushConfigured': _webPushConfigured,\n"
    "      'pushRecipients': _pushSubscriptions.length,\n"
    "      'adminEnabled': _relayAdminHash.isNotEmpty,\n"
    "    });\n"
    "  }"
)
new_health = (
    "  if (request.url.path == 'health') {\n"
    "    final detailToken = Platform.environment['HEALTH_DETAIL_TOKEN'] ?? '';\n"
    "    final wantsDetail = detailToken.isNotEmpty &&\n"
    "        request.headers['x-health-token'] == detailToken;\n"
    "    final body = {\n"
    "      'status': 'ok',\n"
    "      'online': _users.length,\n"
    "      'uptime': DateTime.now().toIso8601String(),\n"
    "      'pushConfigured': _webPushConfigured,\n"
    "      'pushRecipients': _pushSubscriptions.length,\n"
    "      'adminEnabled': _relayAdminHash.isNotEmpty,\n"
    "    };\n"
    "    if (wantsDetail) {\n"
    "      body['peers'] = _users.values\n"
    "          .map((u) => {\n"
    "                'shortId': u.shortId,\n"
    "                'nick': u.nick,\n"
    "                'connectedAt': u.connectedAt.toIso8601String(),\n"
    "              })\n"
    "          .toList();\n"
    "    }\n"
    "    return _jsonResponse(body);\n"
    "  }"
)
rep(old_health, new_health)

# 7. block-list enforcement: packet / blob / search
marker2 = "final Map<String, Set<String>> _blockedByUser = {};"
assert s.count(marker2) == 1
s = s.replace(
    marker2,
    marker2
    + "\n\n"
    "bool _isBlockedByRecipient(String recipientKey, String senderKey) =>\n"
    "    _blockedByUser[recipientKey.toLowerCase()]\n"
    "        ?.contains(senderKey.toLowerCase()) ==\n"
    "    true;",
    1,
)

rep(
    "  final to = toRaw.toLowerCase();\n"
    "  final relayMsgId = (msg['msgId'] as String?) ??\n"
    "      'pkt_${DateTime.now().microsecondsSinceEpoch}';\n"
    "  final senderIsBot = _isKnownBot(sender.publicKey);\n"
    "  final recipientIsBot = _isKnownBot(to);",
    "  final to = toRaw.toLowerCase();\n"
    "  if (_isBlockedByRecipient(to, sender.publicKey)) return;\n"
    "  final relayMsgId = (msg['msgId'] as String?) ??\n"
    "      'pkt_${DateTime.now().microsecondsSinceEpoch}';\n"
    "  final senderIsBot = _isKnownBot(sender.publicKey);\n"
    "  final recipientIsBot = _isKnownBot(to);",
)

rep(
    "  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(routeKey)) {\n"
    "    sender.ws.sink.add(jsonEncode({\n"
    "      'type': 'delivery_status',\n"
    "      'to': routeKey,\n"
    "      'status': 'error',\n"
    "    }));\n"
    "    return;\n"
    "  }\n"
    "  final relayMsgId = msg['msgId'] as String?;\n"
    "  if (relayMsgId == null || relayMsgId.isEmpty) return;\n"
    "  final data = msg['data'] as String?;\n"
    "  if (data == null || data.isEmpty) return;",
    "  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(routeKey)) {\n"
    "    sender.ws.sink.add(jsonEncode({\n"
    "      'type': 'delivery_status',\n"
    "      'to': routeKey,\n"
    "      'status': 'error',\n"
    "    }));\n"
    "    return;\n"
    "  }\n"
    "  if (_isBlockedByRecipient(routeKey, sender.publicKey)) return;\n"
    "  final relayMsgId = msg['msgId'] as String?;\n"
    "  if (relayMsgId == null || relayMsgId.isEmpty) return;\n"
    "  final data = msg['data'] as String?;\n"
    "  if (data == null || data.isEmpty) return;",
)

rep(
    "  for (final user in _users.values) {\n"
    "    if (results.length >= 20) break;\n"
    "    if (user.publicKey == requester.publicKey) continue;\n"
    "    if (_isBotBlockedOrRevoked(user.publicKey)) continue;",
    "  for (final user in _users.values) {\n"
    "    if (results.length >= 20) break;\n"
    "    if (user.publicKey == requester.publicKey) continue;\n"
    "    if (_isBotBlockedOrRevoked(user.publicKey)) continue;\n"
    "    if (_isBlockedByRecipient(user.publicKey, requester.publicKey)) continue;",
)

open(p, 'w', encoding='utf-8').write(s)
print('patched')
