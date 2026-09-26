# Idempotent in-place patch for the relay's server.dart (host copy has
# diverged from git — same pattern as patch_security_phase1.py). Fixes found
# by a second red-team pass against the phase-1-patched relay:
#  1. CRITICAL: `_queueForRecipient` added the new envelope's size to
#     `_mailboxTotalBytes` on every write WITHOUT subtracting the old size when
#     overwriting the same relayMsgId — a sender resending 5 MB under one id
#     (real memory never grows) inflated the counter past the global cap in
#     under 90 s and triggered the "evict globally oldest" fallback, which
#     wiped OTHER users' real queued mail (verified: relay_mailbox.json -> {}).
#  2. HIGH: admin-hash brute-force throttle was keyed by the connection's
#     publicKey — which needs no proof of ownership to register — so a
#     reconnect under a fresh random key reset it every 10 attempts (verified:
#     unlimited practical brute force). Now keyed by the actual TCP remote
#     address, captured at the WebSocket handshake.
#  3. HIGH: `broadcast` (the all-online-users flood path used for ether/
#     profile/story) never checked the recipient's block list — a blocked
#     sender could still reach a victim through it (verified) even though the
#     direct `packet` path was already fixed. Now filtered the same way.
#  4. MEDIUM-HIGH: the `push/subscribe` per-IP rate limit trusted a
#     client-supplied `X-Forwarded-For` header outright — trivially defeated
#     by sending a new value each request (verified) — and the nginx configs
#     in deploy/ never set that header, so it was 100% attacker-controlled.
#     Now ignored unless the operator opts in (env TRUST_FORWARDED_FOR=1),
#     falling back to the real socket peer address.
#  5. MEDIUM: DNS-rebinding TOCTOU — `_isSafePushEndpoint` ran once at
#     subscribe time; the subscription then lives forever, so an attacker's
#     domain could resolve safely at subscribe and be repointed at an internal
#     address before the next push. Re-checked in `_sendWebPush` right before
#     every send.
#  6. MEDIUM: several per-attacker-chosen-key rate-limit maps (blob byte
#     limits, bot register/owner-list/owner-patch, channel-dir-put) were never
#     cleaned on disconnect, unlike `_rateLimits` — unbounded memory growth
#     from repeated reconnects under fresh keys. Now cleaned together.
import sys

p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if '_forgetRateLimitKey' in s:
    print('already patched')
    sys.exit(0)


def rep(old, new, cnt=1):
    global s
    n = s.count(old)
    assert n == cnt, (n, cnt, old[:90])
    s = s.replace(old, new, cnt)


# 1. mailbox byte-accounting fix
rep(
    "  final key = recipientKey.toLowerCase();\n"
    "  final bucket =\n"
    "      _mailbox.putIfAbsent(key, () => <String, Map<String, dynamic>>{});\n"
    "  bucket[relayMsgId] = envelope;\n"
    "  _mailboxTotalBytes += _envelopeApproxBytes(envelope);",
    "  final key = recipientKey.toLowerCase();\n"
    "  final bucket =\n"
    "      _mailbox.putIfAbsent(key, () => <String, Map<String, dynamic>>{});\n"
    "  final old = bucket[relayMsgId];\n"
    "  if (old != null) _mailboxTotalBytes -= _envelopeApproxBytes(old);\n"
    "  bucket[relayMsgId] = envelope;\n"
    "  _mailboxTotalBytes += _envelopeApproxBytes(envelope);",
)

# 2a. _User gains remoteIp
rep(
    "  bool away = false; // true = backgrounded (don't show as online to others)",
    "  bool away = false; // true = backgrounded (don't show as online to others)\n"
    "  final String remoteIp;",
)
rep(
    "      this.x25519Key = '',\n"
    "      this.verified = false});\n"
    "}",
    "      this.x25519Key = '',\n"
    "      this.verified = false,\n"
    "      this.remoteIp = 'unknown'});\n"
    "}",
)

# 2b. admin throttle keyed by IP, everywhere it's checked
rep(
    "  if (!_checkAdminAuthRate(user.publicKey) ||\n"
    "      !_isAdminHashValid(_jsonString(msg['adminHash']))) {",
    "  if (!_checkAdminAuthRate(user.remoteIp) ||\n"
    "      !_isAdminHashValid(_jsonString(msg['adminHash']))) {",
    2,
)
rep(
    "  if (!_checkAdminAuthRate(user.publicKey) || !_isAdminHashValid(oldHash)) {",
    "  if (!_checkAdminAuthRate(user.remoteIp) || !_isAdminHashValid(oldHash)) {",
)
rep(
    "  if (!_checkAdminAuthRate(user.publicKey) || !_isAdminHashValid(adminHash)) {",
    "  if (!_checkAdminAuthRate(user.remoteIp) || !_isAdminHashValid(adminHash)) {",
    2,
)

# 2c. wrap the ws handler to capture the connecting IP, wire it into _User(...)
rep(
    "shelf.Handler _wsHandler() {\n"
    "  // pingInterval=25s включает native WebSocket control-pings (RFC 6455 ping/pong\n"
    "  // на уровне протокола, не application-level). Браузер отвечает автоматически\n"
    "  // без JS-таймеров — не подвержен throttling неактивных табов. Это держит WS\n"
    "  // живым через tuna и другие прокси (обычный idle-timeout 60-120 сек).\n"
    "  return webSocketHandler((WebSocketChannel ws) {",
    "shelf.Handler _wsHandler() {\n"
    "  return (shelf.Request request) {\n"
    "    final remoteIp = _clientIp(request);\n"
    "    final inner = webSocketHandler((WebSocketChannel ws) {",
)
rep(
    "  }, pingInterval: const Duration(seconds: 25));\n"
    "}\n"
    "\n"
    "void _broadcastPresence(String publicKey, bool online) {",
    "    }, pingInterval: const Duration(seconds: 25));\n"
    "    return inner(request);\n"
    "  };\n"
    "}\n"
    "\n"
    "void _broadcastPresence(String publicKey, bool online) {",
)
rep(
    "                publicKey: publicKey,\n"
    "                nick: nick,\n"
    "                x25519Key: x25519Key,\n"
    "                verified: isVerified);",
    "                publicKey: publicKey,\n"
    "                nick: nick,\n"
    "                x25519Key: x25519Key,\n"
    "                verified: isVerified,\n"
    "                remoteIp: remoteIp);",
)

# 6. cleanup helper + wire into onDone/onError (also fixes finding 6)
rep(
    "final Map<String, String> _accountBlobs = {};",
    "void _forgetRateLimitKey(String publicKey) {\n"
    "  _rateLimits.remove(publicKey);\n"
    "  _blobByteLimits.remove(publicKey);\n"
    "  _botRegisterStartLimits.remove(publicKey);\n"
    "  _botOwnerListRateLimits.remove(publicKey);\n"
    "  _botOwnerPatchRateLimits.remove(publicKey);\n"
    "  _channelDirPutLimits.remove(publicKey);\n"
    "}\n\n"
    "final Map<String, String> _accountBlobs = {};",
)
rep(
    "          _users.remove(publicKey);\n"
    "          _rateLimits.remove(publicKey); // free rate-limit memory on disconnect\n"
    "          _broadcastPresence(publicKey, false);",
    "          _users.remove(publicKey);\n"
    "          _forgetRateLimitKey(publicKey);\n"
    "          _broadcastPresence(publicKey, false);",
)
rep(
    "          _users.remove(publicKey);\n"
    "          stdout.writeln('[-] ${user!.shortId} ws error: $e');",
    "          _users.remove(publicKey);\n"
    "          _forgetRateLimitKey(publicKey);\n"
    "          stdout.writeln('[-] ${user!.shortId} ws error: $e');",
)

# 3. block list in broadcast
rep(
    "  // Forward to ALL online users except sender\n"
    "  var sent = 0;\n"
    "  for (final user in _users.values) {\n"
    "    if (user.publicKey == sender.publicKey) continue;\n"
    "    try {",
    "  // Forward to ALL online users except sender (and anyone who blocked us).\n"
    "  var sent = 0;\n"
    "  for (final user in _users.values) {\n"
    "    if (user.publicKey == sender.publicKey) continue;\n"
    "    if (_isBlockedByRecipient(user.publicKey, sender.publicKey)) continue;\n"
    "    try {",
)

# 4. stop trusting X-Forwarded-For by default
rep(
    "String _clientIp(shelf.Request request) {\n"
    "  final fwd = request.headers['x-forwarded-for'];\n"
    "  if (fwd != null && fwd.isNotEmpty) return fwd.split(',').first.trim();\n"
    "  final ci = request.context['shelf.io.connection_info'];\n"
    "  if (ci is HttpConnectionInfo) return ci.remoteAddress.address;\n"
    "  return 'unknown';\n"
    "}",
    "String _clientIp(shelf.Request request) {\n"
    "  if (Platform.environment['TRUST_FORWARDED_FOR'] == '1') {\n"
    "    final fwd = request.headers['x-forwarded-for'];\n"
    "    if (fwd != null && fwd.isNotEmpty) {\n"
    "      final parts = fwd.split(',');\n"
    "      return parts.last.trim();\n"
    "    }\n"
    "  }\n"
    "  final ci = request.context['shelf.io.connection_info'];\n"
    "  if (ci is HttpConnectionInfo) return ci.remoteAddress.address;\n"
    "  return 'unknown';\n"
    "}",
)

# 5. DNS-rebinding re-check right before sending
rep(
    "Future<int> _sendWebPush(\n"
    "    HttpClient client, Map<String, dynamic> sub, List<int>? payload) async {\n"
    "  final endpoint = (sub['endpoint'] as String?)?.trim() ?? '';\n"
    "  final req = await client.postUrl(Uri.parse(endpoint));",
    "Future<int> _sendWebPush(\n"
    "    HttpClient client, Map<String, dynamic> sub, List<int>? payload) async {\n"
    "  final endpoint = (sub['endpoint'] as String?)?.trim() ?? '';\n"
    "  if (!await _isSafePushEndpoint(endpoint)) {\n"
    "    stdout.writeln(\n"
    "        '[RLINK][Push] refusing send: endpoint no longer resolves safely '\n"
    "        '(${Uri.tryParse(endpoint)?.host ?? \"?\"})');\n"
    "    return 400;\n"
    "  }\n"
    "  final req = await client.postUrl(Uri.parse(endpoint));",
)

open(p, 'w', encoding='utf-8').write(s)
print('patched')
