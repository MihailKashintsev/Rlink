// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:js' as js;

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
  if (!html.Notification.supported) return 'unsupported';
  return html.Notification.permission ?? 'default';
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
