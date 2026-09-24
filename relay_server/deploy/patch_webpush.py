import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'encryptWebPushPayload' in s:
    print('already patched'); sys.exit(0)

def rep(old, new):
    global s
    assert s.count(old) == 1, ('anchor count', s.count(old), old[:80])
    s = s.replace(old, new, 1)

rep("import 'oauth.dart';\n", "import 'oauth.dart';\nimport 'webpush_crypto.dart' show encryptWebPushPayload;\n")

rep("""Future<void> _notifyRecipientQueued({""", """/// Sends one Web Push to [sub]. [payload] is encrypted for the subscription
/// (RFC 8291 aes128gcm) — Apple's push service answers an unencrypted body with
/// 400, and FCM accepts it but the browser then drops it. If encryption fails
/// the push goes payloadless so delivery never breaks. Returns the HTTP status.
Future<int> _sendWebPush(
    HttpClient client, Map<String, dynamic> sub, List<int>? payload) async {
  final endpoint = (sub['endpoint'] as String?)?.trim() ?? '';
  final req = await client.postUrl(Uri.parse(endpoint));
  req.headers.set('TTL', '60');
  req.headers.set('Authorization', _vapidAuthHeader(endpoint));
  req.headers.set('Urgency', 'high');
  Uint8List? body;
  final keys = sub['keys'];
  if (payload != null && keys is Map) {
    try {
      body = encryptWebPushPayload(
        plaintext: Uint8List.fromList(payload),
        p256dhB64Url: (keys['p256dh'] as String?) ?? '',
        authB64Url: (keys['auth'] as String?) ?? '',
      );
    } catch (e) {
      stdout.writeln('[RLINK][Push] encrypt failed (${Uri.parse(endpoint).host}): $e');
    }
  }
  if (body != null) {
    req.headers.set('Content-Encoding', 'aes128gcm');
    req.headers.set('Content-Type', 'application/octet-stream');
    req.contentLength = body.length;
    req.add(body);
  } else {
    req.contentLength = 0;
  }
  final resp = await req.close();
  if (resp.statusCode >= 300) {
    // Log the push service's reason (e.g. Apple's BadEncoding) for diagnosis.
    final reason = await resp
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 3), onTimeout: () => '');
    stdout.writeln('[RLINK][Push] ${resp.statusCode} '
        '${Uri.parse(endpoint).host} reason: '
        '${reason.length > 200 ? reason.substring(0, 200) : reason}');
  } else {
    await resp.drain<void>();
  }
  return resp.statusCode;
}

Future<void> _notifyRecipientQueued({""")

rep("""  final payload = utf8.encode(jsonEncode({
    'title': 'Rlink',""", """  final senderNick = _users[senderKey]?.nick.trim() ?? '';
  final payload = utf8.encode(jsonEncode({
    'title': senderNick.isNotEmpty ? senderNick : 'Rlink',""")

rep("""        final req = await client.postUrl(Uri.parse(endpoint));
        req.headers.set('TTL', '60');
        req.headers.set('Authorization', _vapidAuthHeader(endpoint));
        req.headers.set('Urgency', 'high');
        req.headers.set('Content-Type', 'application/json');
        req.add(payload);
        final resp = await req.close();
        // 403 = the subscription's VAPID key no longer matches ours; like
        // 404/410 it can never succeed, so drop it and let the client
        // re-subscribe fresh on its next sync.
        if (resp.statusCode == 403 ||
            resp.statusCode == 404 ||
            resp.statusCode == 410) {
          toRemoveEndpoints.add(endpoint);
        }
        stdout.writeln('[RLINK][Push] ${resp.statusCode} '""", """        final status = await _sendWebPush(client, sub, payload);
        // 403 = the subscription's VAPID key no longer matches ours; like
        // 404/410 it can never succeed, so drop it and let the client
        // re-subscribe fresh on its next sync.
        if (status == 403 || status == 404 || status == 410) {
          toRemoveEndpoints.add(endpoint);
        }
        stdout.writeln('[RLINK][Push] $status '""")

rep("""            // Payloadless push (Web Push rejects unencrypted payloads → 400).
            final req = await client.postUrl(Uri.parse(endpoint));
            req.headers.set('TTL', '60');
            req.headers.set('Authorization', _vapidAuthHeader(endpoint));
            req.headers.set('Urgency', 'high');
            final resp = await req.close();
            if (resp.statusCode == 403 ||
                resp.statusCode == 404 ||
                resp.statusCode == 410) {
              toRemove.add(endpoint);
            } else if (resp.statusCode >= 200 && resp.statusCode < 300) {
              sent++;
            }
            stdout.writeln(
                '[RLINK][Push][test] ${resp.statusCode} ${Uri.parse(endpoint).host}');""", """            final status = await _sendWebPush(
                client,
                sub,
                utf8.encode(jsonEncode({
                  'title': 'Rlink',
                  'body': 'Проверка уведомлений',
                  'tag': 'rlink-test',
                })));
            if (status == 403 || status == 404 || status == 410) {
              toRemove.add(endpoint);
            } else if (status >= 200 && status < 300) {
              sent++;
            }
            stdout.writeln(
                '[RLINK][Push][test] $status ${Uri.parse(endpoint).host}');""")
open(p, 'w', encoding='utf-8').write(s)
print('patched')
