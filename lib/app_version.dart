import 'package:flutter/foundation.dart';

/// Версия для отображения в UI. При релизе обновляй вместе с [pubspec.yaml] `version: X.Y.Z+N`.
class AppVersion {
  AppVersion._();

  static const String version = '1.0.4';
  static const String buildNumber = '22';
  static const String webPushId =
      String.fromEnvironment('RLINK_WEB_PUSH_ID', defaultValue: '');

  static String get label => '$version ($buildNumber)';
  static String get webPushLabel {
    if (!kIsWeb) return '';
    return 'Web push ${webPushId.isEmpty ? 'unknown' : webPushId}';
  }
}
