import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Версия приложения. Значения подтягиваются автоматически из установленного
/// пакета через [init] (PackageInfo → pubspec `version:`), поэтому вручную
/// править их при релизе больше не нужно. Const-поля ниже — только фолбэк на
/// случай, если PackageInfo ещё не успел загрузиться.
class AppVersion {
  AppVersion._();

  static const String _fallbackVersion = '1.2.2';
  static const String _fallbackBuild = '35';

  static String _version = _fallbackVersion;
  static String _buildNumber = _fallbackBuild;

  static const String webPushId =
      String.fromEnvironment('RLINK_WEB_PUSH_ID', defaultValue: '');

  static String get version => _version;
  static String get buildNumber => _buildNumber;

  /// Читает реальную версию установленного приложения. Вызывать один раз при
  /// старте (в `main`), до построения UI. Безопасно падает на фолбэк.
  static Future<void> init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) _version = info.version;
      if (info.buildNumber.isNotEmpty) _buildNumber = info.buildNumber;
    } catch (_) {
      // keep fallback constants
    }
  }

  static String get label => '$version ($buildNumber)';
  static String get webPushLabel {
    if (!kIsWeb) return '';
    return 'Web push ${webPushId.isEmpty ? 'unknown' : webPushId}';
  }
}
