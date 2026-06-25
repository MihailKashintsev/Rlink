import 'dart:typed_data';

import 'web_video_frames_stub.dart'
    if (dart.library.html) 'web_video_frames_web.dart' as impl;

/// Frame thumbnails (JPEG bytes) extracted from a web video URL.
Future<List<Uint8List>> webVideoThumbnails(String url, {int count = 8}) =>
    impl.webVideoThumbnails(url, count: count);
