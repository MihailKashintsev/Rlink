import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'message_actions_overlay.dart';

/// Captures the widget behind [boundaryKey] (a keyed RepaintBoundary) and shows
/// the Telegram-style blur action overlay — the same one chat uses, so channels,
/// groups and comments get identical long-press UX.
Future<void> showBubbleActions({
  required BuildContext context,
  required GlobalKey boundaryKey,
  required List<MessageMenuAction> actions,
  void Function(String emoji)? onReact,
  VoidCallback? onMoreReactions,
}) async {
  final ro = boundaryKey.currentContext?.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize) return;
  final rect = ro.localToGlobal(Offset.zero) & ro.size;
  ui.Image? image;
  // `debugNeedsPaint` throws LateInitializationError in RELEASE builds — never
  // use it in production. toImage is guarded by the try/catch below.
  if (!kIsWeb && ro is RenderRepaintBoundary) {
    try {
      image = await ro
          .toImage(pixelRatio: MediaQuery.of(context).devicePixelRatio)
          .timeout(const Duration(milliseconds: 600));
    } catch (_) {
      image = null;
    }
  }
  if (!context.mounted) {
    image?.dispose();
    return;
  }
  await showMessageActionsOverlay(
    context: context,
    bubbleRect: rect,
    snapshot: image,
    actions: actions,
    onReact: onReact,
    onMoreReactions: onMoreReactions,
  );
  image?.dispose();
}
