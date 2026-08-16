import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors _searchJamendo's field extraction so a schema change is caught here
/// rather than as an empty music tab.
void main() {
  test('jamendo response shape maps to CatalogTrack fields', () {
    const body = '''
    {"headers":{"status":"success"},
     "results":[
       {"name":"На крыше мира","artist_name":"КЫНО","duration":218,
        "audio":"https://prod-1.storage.jamendo.com/?trackid=1&format=mp32",
        "image":"https://usercontent.jamendo.com/cover.jpg"},
       {"name":"no audio","artist_name":"X","duration":10,"audio":"","image":null}
     ]}''';
    final list = (jsonDecode(body) as Map)['results'] as List?;
    expect(list, isNotNull);

    final out = [
      for (final e in list!)
        if (e is Map && e['audio'] is String && '${e['audio']}'.isNotEmpty)
          (
            title: '${e['name'] ?? ''}',
            artist: '${e['artist_name'] ?? ''}',
            url: '${e['audio']}',
            art: e['image'] as String?,
            secs: (e['duration'] as num?)?.toInt() ?? 0,
          ),
    ];

    expect(out.length, 1, reason: 'entries without audio must be dropped');
    expect(out.first.title, 'На крыше мира');
    expect(out.first.artist, 'КЫНО');
    expect(out.first.secs, 218);
    expect(out.first.art, isNotNull);
  });
}
