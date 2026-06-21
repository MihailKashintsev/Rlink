import 'dart:js_interop';
import 'package:web/web.dart' as web;

/// Logs directly to the browser console — visible even in release web builds
/// (unlike Flutter's debugPrint, which is suppressed in release).
void webConsoleLog(String msg) => web.console.log(msg.toJS);
