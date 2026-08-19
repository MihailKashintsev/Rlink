import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/models/tgs_sticker.dart';

void main() {
  Uint8List gzipJson(Object json) =>
      Uint8List.fromList(GZipEncoder().encode(utf8.encode(jsonEncode(json))));

  test('gunzipTgsToLottieJson round-trips a hand-gzipped Lottie-shaped fixture', () {
    final lottie = {'v': '5.5.7', 'fr': 60, 'w': 512, 'h': 512, 'layers': []};
    final tgsBytes = gzipJson(lottie);
    final out = gunzipTgsToLottieJson(tgsBytes);
    expect(out, isNotNull);
    expect(jsonDecode(utf8.decode(out!)), lottie);
  });

  test('gunzipTgsToLottieJson returns null on non-gzip garbage', () {
    expect(gunzipTgsToLottieJson(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('gunzipTgsToLottieJson returns null when gzip payload is not JSON', () {
    final notJson = Uint8List.fromList(GZipEncoder().encode(utf8.encode('not json')));
    expect(gunzipTgsToLottieJson(notJson), isNull);
  });

  test('gunzipTgsToLottieJson returns null when gzip payload is a JSON array, not an object', () {
    expect(gunzipTgsToLottieJson(gzipJson([1, 2, 3])), isNull);
  });

  group('looksLikeTgsRef', () {
    test('native and OPFS paths are matched by extension', () {
      expect(looksLikeTgsRef('/docs/images/stk_x.tgs'), isTrue);
      expect(looksLikeTgsRef('opfs://rlink/abc_sticker.tgs'), isTrue);
      expect(looksLikeTgsRef('opfs://rlink/abc_sticker.tgs#frag'), isTrue);
      expect(looksLikeTgsRef('/docs/images/stk_x.png'), isFalse);
    });

    test('web data refs are matched by MIME, not extension', () {
      expect(looksLikeTgsRef('data:$tgsMimeType;base64,AAAA'), isTrue);
      expect(looksLikeTgsRef('data:image/png;base64,AAAA'), isFalse);
    });
  });
}
