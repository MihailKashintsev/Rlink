// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Ask the browser to mark our storage (IndexedDB / localStorage / OPFS) as
/// persistent so it isn't evicted under storage pressure or after inactivity —
/// without this, channel settings, the linked Google account and cached media
/// can silently disappear between sessions (especially on iOS Safari).
Future<bool> requestPersistentStorage() async {
  try {
    final storage = web.window.navigator.storage;
    // Already persistent? Don't re-prompt.
    final already = await storage.persisted().toDart;
    if (already.toDart) return true;
    final granted = await storage.persist().toDart;
    return granted.toDart;
  } catch (_) {
    return false;
  }
}
