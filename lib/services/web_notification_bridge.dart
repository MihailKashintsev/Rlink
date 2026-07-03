import 'web_notification_bridge_stub.dart'
    if (dart.library.html) 'web_notification_bridge_web.dart' as impl;

Future<void> requestWebNotificationPermission() =>
    impl.requestWebNotificationPermission();

Future<String> webNotificationPermission() => impl.webNotificationPermission();

Future<Map<String, Object?>> webNotificationCapability() =>
    impl.webNotificationCapability();

Future<void> showWebNotification({
  required String title,
  required String body,
  String? tag,
}) =>
    impl.showWebNotification(title: title, body: body, tag: tag);

Future<void> syncWebPushSubscription({
  required String relayServerUrl,
  required String publicKey,
  required String nick,
}) =>
    impl.syncWebPushSubscription(
      relayServerUrl: relayServerUrl,
      publicKey: publicKey,
      nick: nick,
    );

/// User-initiated background-push enable. Requests permission if needed and
/// force-subscribes (bypassing the background sync's debounce). Returns
/// `{ok, reason, detail?}`.
Future<Map<String, Object?>> enableWebPush({
  required String relayServerUrl,
  required String publicKey,
  required String nick,
}) =>
    impl.enableWebPush(
      relayServerUrl: relayServerUrl,
      publicKey: publicKey,
      nick: nick,
    );

/// Asks the relay to send a test push to my own subscription. Returns
/// `{ok, reason, sent}`.
Future<Map<String, Object?>> testWebPush({
  required String relayServerUrl,
  required String publicKey,
}) =>
    impl.testWebPush(
      relayServerUrl: relayServerUrl,
      publicKey: publicKey,
    );

Future<String> requestWebMediaPermission({
  required bool audio,
  required bool video,
}) =>
    impl.requestWebMediaPermission(audio: audio, video: video);

Future<String> webMediaPermissionStatus(String name) =>
    impl.webMediaPermissionStatus(name);
