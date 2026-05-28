/// Версия для отображения в UI. При релизе обновляй вместе с [pubspec.yaml] `version: X.Y.Z+N`.
class AppVersion {
  AppVersion._();

  static const String version = '0.0.9';
  static const String buildNumber = '15';
  static const String webPushId =
      String.fromEnvironment('RLINK_WEB_PUSH_ID', defaultValue: '');

  static String get label => '$version ($buildNumber)';
  static String get webPushLabel =>
      webPushId.isEmpty ? '' : 'Web push $webPushId';
}
