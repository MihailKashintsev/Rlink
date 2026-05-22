import 'dart:typed_data';

import 'web_file_store_stub.dart'
    if (dart.library.html) 'web_file_store_web.dart' as impl;

const webStoredFilePrefix = 'opfs://rlink/';

bool isWebStoredFile(String path) => path.startsWith(webStoredFilePrefix);

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

Future<void> downloadWebFile(
  String path, {
  required String fileName,
  required String mimeType,
}) =>
    impl.downloadWebFile(path, fileName: fileName, mimeType: mimeType);
