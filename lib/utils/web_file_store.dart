import 'dart:typed_data';

import 'web_file_store_stub.dart'
    if (dart.library.html) 'web_file_store_web.dart' as impl;

const webStoredFilePrefix = 'opfs://rlink/';

bool isWebStoredFile(String path) => path.startsWith(webStoredFilePrefix);

String webVideoMimeForPath(String path, {String fallback = 'video/mp4'}) {
  final clean = path.split('#').first.split('?').first.toLowerCase();
  if (clean.startsWith('data:video/webm')) return 'video/webm';
  if (clean.startsWith('data:video/quicktime')) return 'video/quicktime';
  if (clean.startsWith('data:video/mp4')) return 'video/mp4';
  if (clean.endsWith('.webm')) return 'video/webm';
  if (clean.endsWith('.mov')) return 'video/quicktime';
  if (clean.endsWith('.m4v') || clean.endsWith('.mp4')) return 'video/mp4';
  return fallback;
}

/// General filename → mime for web-picked bytes (image/video/other). Used
/// when writing picked gif/video/file bytes to OPFS so playback/rendering
/// gets the right content-type.
String webMimeForFileName(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'webm':
      return 'video/webm';
    case 'mov':
      return 'video/quicktime';
    case 'mp4':
    case 'm4v':
      return 'video/mp4';
    default:
      return 'application/octet-stream';
  }
}

List<String> webVideoMimeCandidatesForPath(String path) {
  final primary = webVideoMimeForPath(path);
  return <String>{
    primary,
    'video/mp4',
    'video/webm',
    'video/quicktime',
  }.toList(growable: false);
}

Future<String?> writeWebStoredFile({
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
}) =>
    impl.writeWebStoredFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType,
    );

Future<Uint8List?> readWebStoredFile(String path) =>
    impl.readWebStoredFile(path);

Future<String?> webStoredFileObjectUrl(
  String path, {
  required String mimeType,
}) =>
    impl.webStoredFileObjectUrl(path, mimeType: mimeType);

String? webBytesObjectUrl(List<int> bytes, {required String mimeType}) =>
    impl.webBytesObjectUrl(bytes, mimeType: mimeType);

Future<void> downloadWebFile(
  String path, {
  required String fileName,
  required String mimeType,
}) =>
    impl.downloadWebFile(path, fileName: fileName, mimeType: mimeType);
