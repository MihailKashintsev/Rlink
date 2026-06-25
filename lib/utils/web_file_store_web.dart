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
    // Verify the bytes actually persisted. Some browsers' OPFS
    // createWritable() silently yields a 0-byte file; when that happens we
    // return null so the caller falls back to an inline data: URI that keeps
    // the real bytes (and the correct size).
    final written = await fh.getFile().toDart;
    if (written.size != bytes.length) {
      return null;
    }
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

/// Creates an in-memory blob object URL from raw bytes (e.g. to preview a
/// just-picked video in a player before sending). Caller should revoke it.
String? webBytesObjectUrl(List<int> bytes, {required String mimeType}) {
  try {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final blob = web.Blob([data.toJS].toJS,
        web.BlobPropertyBag(type: mimeType.isEmpty ? 'video/mp4' : mimeType));
    return web.URL.createObjectURL(blob);
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
    // Always materialize into an in-memory Blob. Object URLs of OPFS-backed
    // File objects reject the byte-range requests that <video>/<audio> issue
    // (notably the trailing end-range a player uses to read an MP4 `moov`
    // atom) → 416 ERR_REQUEST_RANGE_NOT_SATISFIABLE, which breaks playback of
    // received media on web. A plain in-memory Blob serves ranges reliably.
    // Do NOT use file.slice()-retyping either (same range failure in Chromium).
    final ab = await file.arrayBuffer().toDart;
    final requestedType = mimeType.trim();
    final type = requestedType.isEmpty ? file.type : requestedType;
    final blob = web.Blob([ab].toJS, web.BlobPropertyBag(type: type));
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
