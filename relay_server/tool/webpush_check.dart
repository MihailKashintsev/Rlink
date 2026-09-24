// Manual check for bin/webpush_crypto.dart:
//   dart run tool/webpush_check.dart rfc                       → RFC 8291 App. A body
//   dart run tool/webpush_check.dart enc <p256dh> <auth> <text> → random-key body
import 'dart:convert';
import 'dart:typed_data';

import '../bin/webpush_crypto.dart';

Uint8List b64u(String s) {
  var n = s.replaceAll('-', '+').replaceAll('_', '/');
  while (n.length % 4 != 0) {
    n += '=';
  }
  return Uint8List.fromList(base64Decode(n));
}

String enc(List<int> b) => base64Url.encode(b).replaceAll('=', '');

void main(List<String> args) {
  if (args.isNotEmpty && args[0] == 'rfc') {
    final body = encryptWebPushPayload(
      plaintext: Uint8List.fromList(
          utf8.encode('When I grow up, I want to be a watermelon')),
      p256dhB64Url:
          'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
      authB64Url: 'BTBZMqHH6r4Tts7J_aSIgg',
      asPrivate: b64u('yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw'),
      salt: b64u('DGv6ra1nlYgDCS1FRnbzlw'),
    );
    print(enc(body));
    return;
  }
  print(enc(encryptWebPushPayload(
    plaintext: Uint8List.fromList(utf8.encode(args[2])),
    p256dhB64Url: args[0],
    authB64Url: args[1],
  )));
}
