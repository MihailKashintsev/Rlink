import 'dart:typed_data';

import 'web_object_url_stub.dart'
    if (dart.library.html) 'web_object_url_web.dart' as impl;

String? createWebObjectUrl(List<Uint8List> chunks, String mimeType) =>
    impl.createWebObjectUrl(chunks, mimeType);
