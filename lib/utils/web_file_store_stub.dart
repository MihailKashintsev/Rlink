import 'dart:typed_data';

Future<String?> writeWebStoredFile({
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
}) async =>
    null;

Future<Uint8List?> readWebStoredFile(String path) async => null;

Future<String?> webStoredFileObjectUrl(
  String path, {
  required String mimeType,
}) async =>
    null;

Future<void> downloadWebFile(
  String path, {
  required String fileName,
  required String mimeType,
}) async {}
