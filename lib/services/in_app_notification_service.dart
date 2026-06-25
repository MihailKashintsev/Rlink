import 'dart:async';

import 'package:flutter/foundation.dart';

/// A lightweight in-app notification (shown as a banner sliding from the top
/// when a message/call arrives while the app is open in another screen).
class InAppNotif {
  final String title;
  final String body;
  final String payload; // 'dm:<peerId>' | 'group:<id>' | 'channel:<id>'
  final int color;
  final String emoji;
  final String? imagePath;
  final bool isCall;
  final int seq;
  const InAppNotif({
    required this.title,
    required this.body,
    required this.payload,
    required this.color,
    this.emoji = '',
    this.imagePath,
    this.isCall = false,
    required this.seq,
  });
}

class InAppNotificationService {
  InAppNotificationService._();
  static final InAppNotificationService instance = InAppNotificationService._();

  final ValueNotifier<InAppNotif?> current = ValueNotifier<InAppNotif?>(null);
  int _seq = 0;
  Timer? _timer;

  /// Set by the app shell — opens the chat/channel for a tapped banner payload.
  void Function(String payload)? onOpen;

  void show({
    required String title,
    required String body,
    required String payload,
    required int color,
    String emoji = '',
    String? imagePath,
    bool isCall = false,
  }) {
    current.value = InAppNotif(
      title: title,
      body: body,
      payload: payload,
      color: color,
      emoji: emoji,
      imagePath: imagePath,
      isCall: isCall,
      seq: ++_seq,
    );
    _timer?.cancel();
    _timer = Timer(
      Duration(seconds: isCall ? 8 : 4),
      dismiss,
    );
  }

  void dismiss() {
    _timer?.cancel();
    if (current.value != null) current.value = null;
  }
}
