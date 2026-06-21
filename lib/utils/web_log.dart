// Web-visible console logging. Flutter `debugPrint` is suppressed in release
// web builds, so diagnostic logs never reach the browser console. This helper
// calls console.log directly on web (always visible) and falls back to
// debugPrint on native.
export 'web_log_stub.dart' if (dart.library.html) 'web_log_web.dart';
