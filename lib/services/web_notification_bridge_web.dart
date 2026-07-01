// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:js' as js;

bool _hasGlobal(String name) {
  try {
    return js.context.hasProperty(name);
  } catch (_) {
    return false;
  }
}

Object? _navigatorValue(String name) {
  try {
    final navigator = js.context['navigator'];
    if (navigator is! js.JsObject || !navigator.hasProperty(name)) {
      return null;
    }
    return navigator[name];
  } catch (_) {
    return null;
  }
}

bool _navigatorBool(String name) => _navigatorValue(name) == true;

int _navigatorInt(String name) {
  final value = _navigatorValue(name);
  if (value is num) return value.toInt();
  return 0;
}

bool _matchesMedia(String query) {
  try {
    return html.window.matchMedia(query).matches;
  } catch (_) {
    return false;
  }
}

bool _isStandaloneWebApp() {
  return _matchesMedia('(display-mode: standalone)') ||
      _matchesMedia('(display-mode: fullscreen)') ||
      _navigatorBool('standalone');
}

bool _isIOSWebKit() {
  final ua = html.window.navigator.userAgent.toLowerCase();
  return ua.contains('iphone') ||
      ua.contains('ipad') ||
      ua.contains('ipod') ||
      (ua.contains('macintosh') && _navigatorInt('maxTouchPoints') > 1);
}

bool _isSafariLike() {
  final ua = html.window.navigator.userAgent.toLowerCase();
  return ua.contains('safari') &&
      !ua.contains('chrome') &&
      !ua.contains('crios') &&
      !ua.contains('fxios') &&
      !ua.contains('edg') &&
      !ua.contains('android');
}

Future<void> requestWebNotificationPermission() async {
  if (!html.Notification.supported) return;
  try {
    final perm = await html.Notification.requestPermission();
    if (perm == 'granted' && html.window.navigator.serviceWorker != null) {
      await html.window.navigator.serviceWorker?.register('push_sw.js');
    }
  } catch (_) {}
}

Future<String> webNotificationPermission() async {
  final capability = await webNotificationCapability();
  return (capability['status'] as String?) ?? 'unsupported';
}

Future<Map<String, Object?>> webNotificationCapability() async {
  final isIOS = _isIOSWebKit();
  final standalone = _isStandaloneWebApp();
  final isSafari = _isSafariLike();
  final notificationSupported =
      html.Notification.supported || _hasGlobal('Notification');
  final serviceWorkerSupported = html.window.navigator.serviceWorker != null;
  final pushSupported = _hasGlobal('PushManager');
  final permission = notificationSupported
      ? (html.Notification.permission ?? 'default')
      : 'unsupported';

  String status;
  String label;
  bool canRequest;

  if (isIOS && !standalone) {
    status = 'ios_install_required';
    label =
        'На iPhone/iPad Safari push-уведомления работают только после добавления Rlink на экран Домой';
    canRequest = false;
  } else if (!notificationSupported) {
    status = 'unsupported_notifications';
    label = 'Браузер не отдает Notifications API';
    canRequest = false;
  } else if (!serviceWorkerSupported) {
    status = 'unsupported_service_worker';
    label = 'Service Worker недоступен на этом адресе';
    canRequest = false;
  } else if (!pushSupported) {
    status = 'unsupported_push';
    label = isSafari
        ? 'Safari сейчас не отдает Push API для этой вкладки'
        : 'Браузер не отдает Push API';
    canRequest = false;
  } else {
    status = permission;
    label = switch (permission) {
      'granted' => 'Разрешены',
      'denied' => 'Запрещены в настройках браузера',
      _ => 'Нужно разрешение браузера',
    };
    canRequest = permission != 'denied';
  }

  return {
    'status': status,
    'permission': permission,
    'label': label,
    'canRequest': canRequest,
    'notificationSupported': notificationSupported,
    'serviceWorkerSupported': serviceWorkerSupported,
    'pushSupported': pushSupported,
    'standalone': standalone,
    'isIOS': isIOS,
    'isSafari': isSafari,
  };
}

Future<void> showWebNotification({
  required String title,
  required String body,
  String? tag,
}) async {
  if (!html.Notification.supported) return;
  if (html.Notification.permission != 'granted') return;
  try {
    final sw = html.window.navigator.serviceWorker;
    if (sw != null) {
      final reg = await sw.ready;
      await reg.showNotification(
        title,
        {
          'body': body,
          'tag': tag,
          'renotify': true,
          'icon': 'icons/Icon-192.png',
          'badge': 'icons/Icon-192.png',
        },
      );
      return;
    }
    html.Notification(
      title,
      body: body,
      tag: tag,
    );
  } catch (_) {}
}

/// Triggers the browser mic/camera permission prompt via getUserMedia, then
/// immediately stops the tracks (we only wanted the grant). Returns
/// 'granted' | 'denied' | 'error' | 'unsupported'.
Future<String> requestWebMediaPermission({
  required bool audio,
  required bool video,
}) async {
  try {
    final md = html.window.navigator.mediaDevices;
    if (md == null) return 'unsupported';
    final stream = await md.getUserMedia({'audio': audio, 'video': video});
    for (final t in stream.getTracks()) {
      try {
        t.stop();
      } catch (_) {}
    }
    return 'granted';
  } catch (e) {
    final s = e.toString().toLowerCase();
    if (s.contains('notallowed') ||
        s.contains('denied') ||
        s.contains('permission')) {
      return 'denied';
    }
    return 'error';
  }
}

/// Current permission state without prompting. 'granted'|'denied'|'prompt'|
/// 'unknown' ('unknown' e.g. on iOS Safari which lacks permissions.query for
/// camera/microphone).
Future<String> webMediaPermissionStatus(String name) async {
  try {
    final perms = html.window.navigator.permissions;
    if (perms == null) return 'unknown';
    final status = await perms.query({'name': name});
    return status.state ?? 'unknown';
  } catch (_) {
    return 'unknown';
  }
}

Future<void> syncWebPushSubscription({
  required String relayServerUrl,
  required String publicKey,
  required String nick,
}) async {
  try {
    js.context.callMethod('rlinkSyncPushSubscription', [
      relayServerUrl,
      publicKey,
      nick,
    ]);
  } catch (_) {}
}
