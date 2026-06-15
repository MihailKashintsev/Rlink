Future<void> requestWebNotificationPermission() async {}

Future<String> webNotificationPermission() async => 'unsupported';

Future<Map<String, Object?>> webNotificationCapability() async => {
      'status': 'unsupported',
      'permission': 'unsupported',
      'label': 'Не поддерживаются на этой платформе',
      'canRequest': false,
      'notificationSupported': false,
      'serviceWorkerSupported': false,
      'pushSupported': false,
      'standalone': false,
      'isIOS': false,
      'isSafari': false,
    };

Future<void> showWebNotification({
  required String title,
  required String body,
  String? tag,
}) async {}

Future<void> syncWebPushSubscription({
  required String relayServerUrl,
  required String publicKey,
  required String nick,
}) async {}
