// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

const _prefix = 'opfs://rlink/';
const _directory = 'rlink_files';

String _safeFileName(String fileName) {
  final safe = fileName
      .trim()
      .replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_');
  return safe.isEmpty ? 'file.bin' : safe;
}

Future<web.FileSystemDirectoryHandle> _filesDirectory() async {
  final root = await web.window.navigator.storage.getDirectory().toDart;
  return root
      .getDirectoryHandle(
        _directory,
        web.FileSystemGetDirectoryOptions(create: true),
      )
      .toDart;
}

Future<web.File?> _readFile(String path) async {
  if (!path.startsWith(_prefix)) return null;
  final name = path.substring(_prefix.length);
  if (name.isEmpty) return null;
  final dir = await _filesDirectory();
  final fh = await dir
      .getFileHandle(
        name,
        web.FileSystemGetFileOptions(create: false),
      )
      .toDart;
  return fh.getFile().toDart;
}

Future<String?> writeWebStoredFile({
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
}) async {
  try {
    final safeName = _safeFileName(fileName);
    final dir = await _filesDirectory();
    final fh = await dir
        .getFileHandle(
          safeName,
          web.FileSystemGetFileOptions(create: true),
        )
        .toDart;
    final writable = await fh.createWritable().toDart;
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    await writable.write(blob).toDart;
    await writable.close().toDart;
    return '$_prefix$safeName';
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> readWebStoredFile(String path) async {
  try {
    final file = await _readFile(path);
    if (file == null) return null;
    final buffer = await file.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  } catch (_) {
    return null;
  }
}

Future<String?> webStoredFileObjectUrl(
  String path, {
  required String mimeType,
}) async {
  try {
    final file = await _readFile(path);
    if (file == null) return null;
    final blob = file.type.isEmpty ? file.slice(0, file.size, mimeType) : file;
    return web.URL.createObjectURL(blob);
  } catch (_) {
    return null;
  }
}

Future<void> downloadWebFile(
  String path, {
  required String fileName,
  required String mimeType,
}) async {
  String? objectUrl;
  var href = path;
  try {
    if (path.startsWith(_prefix)) {
      objectUrl = await webStoredFileObjectUrl(path, mimeType: mimeType);
      if (objectUrl == null) return;
      href = objectUrl;
    }
    final a = web.HTMLAnchorElement()
      ..href = href
      ..download = _safeFileName(fileName);
    web.document.body?.appendChild(a);
    a.click();
    a.remove();
  } finally {
    if (objectUrl != null) {
      web.URL.revokeObjectURL(objectUrl);
    }
  }
}
