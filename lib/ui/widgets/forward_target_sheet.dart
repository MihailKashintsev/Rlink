import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../l10n/app_l10n.dart';
import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import 'avatar_widget.dart';

/// The on-screen rect of the button that triggered a forward — pass via
/// [showForwardDmTargetSheet]'s `anchorRect` so the picker can grow out of
/// it instead of sliding up as a generic bottom sheet. Grab it right before
/// the `await` in the button's own `onTap`/`onPressed`, while its context
/// is still mounted.
Rect? forwardAnchorRectOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached) return null;
  final origin = box.localToGlobal(Offset.zero);
  return origin & box.size;
}

/// Строка списка «переслать в…» (личные чаты + избранное), в духе вкладки «Чаты».
class ForwardDmTargetPick {
  final String peerId;
  final String nickname;
  final int avatarColor;
  final String avatarEmoji;
  final String? avatarImagePath;
  final DateTime lastTime;
  final bool isSavedMessages;

  const ForwardDmTargetPick({
    required this.peerId,
    required this.nickname,
    required this.avatarColor,
    required this.avatarEmoji,
    this.avatarImagePath,
    required this.lastTime,
    this.isSavedMessages = false,
  });
}

Future<List<ForwardDmTargetPick>> loadForwardDmTargets({
  String? excludePeerId,
}) async {
  final items = <ForwardDmTargetPick>[];
  final myId = CryptoService.instance.publicKeyHex;

  final summaries = await ChatStorageService.instance.getChatSummaries();
  final summaryIds = <String>{};
  for (final s in summaries) {
    if (myId.isNotEmpty && s.peerId == myId) continue;
    if (excludePeerId != null && s.peerId == excludePeerId) continue;
    summaryIds.add(s.peerId);
    items.add(ForwardDmTargetPick(
      peerId: s.peerId,
      nickname: s.nickname ??
          '${s.peerId.substring(0, s.peerId.length.clamp(0, 8))}...',
      avatarColor: s.avatarColor ?? 0xFF607D8B,
      avatarEmoji: s.avatarEmoji ?? '',
      avatarImagePath: s.avatarImagePath,
      lastTime: s.timestamp,
    ));
  }

  final contacts = await ChatStorageService.instance.getContacts();
  for (final c in contacts) {
    if (myId.isNotEmpty && c.publicKeyHex == myId) continue;
    if (summaryIds.contains(c.publicKeyHex)) continue;
    if (excludePeerId != null && c.publicKeyHex == excludePeerId) continue;
    items.add(ForwardDmTargetPick(
      peerId: c.publicKeyHex,
      nickname: c.nickname.isNotEmpty
          ? c.nickname
          : '${c.publicKeyHex.substring(0, 8)}...',
      avatarColor: c.avatarColor,
      avatarEmoji: c.avatarEmoji,
      avatarImagePath: c.avatarImagePath,
      lastTime: c.addedAt,
    ));
  }

  items.sort((a, b) => b.lastTime.compareTo(a.lastTime));

  if (myId.isNotEmpty &&
      (excludePeerId == null || excludePeerId != myId)) {
    final savedLast = await ChatStorageService.instance.getLastMessage(myId);
    final savedTime =
        savedLast?.timestamp ?? DateTime.fromMillisecondsSinceEpoch(0);
    items.insert(
      0,
      ForwardDmTargetPick(
        peerId: myId,
        nickname: AppL10n.t('chat_saved_messages'),
        avatarColor: 0xFF26A69A,
        avatarEmoji: '⭐',
        avatarImagePath: null,
        lastTime: savedTime,
        isSavedMessages: true,
      ),
    );
  }

  return items;
}

/// Модальное окно выбора чата для пересылки (Telegram-style).
///
/// Pass [anchorRect] (from [forwardAnchorRectOf]) to have the picker grow
/// out of the button that triggered it — a blurred glass panel scaling in
/// from that corner, matching the "+"-menu and search palette elsewhere in
/// this batch — instead of the plain bottom sheet used when it's omitted.
Future<ForwardDmTargetPick?> showForwardDmTargetSheet(
  BuildContext context, {
  String? excludePeerId,
  Rect? anchorRect,
}) async {
  final targets = await loadForwardDmTargets(excludePeerId: excludePeerId);
  if (!context.mounted) return null;
  if (targets.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          excludePeerId != null
              ? AppL10n.t('Нет других чатов для пересылки')
              : AppL10n.t('Нет чатов для пересылки'),
        ),
      ),
    );
    return null;
  }

  if (anchorRect != null) {
    return showGeneralDialog<ForwardDmTargetPick>(
      context: context,
      barrierDismissible: true,
      barrierLabel: AppL10n.t('common_cancel'),
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (ctx, anim, __) => _ForwardMorphOverlay(
        anchorRect: anchorRect,
        targets: targets,
        animation: anim,
      ),
    );
  }

  return showModalBottomSheet<ForwardDmTargetPick>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final h = MediaQuery.sizeOf(ctx).height * 0.55;
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(ctx).bottom,
          ),
          child: SizedBox(
            height: h,
            child: _ForwardSheetBody(targets: targets),
          ),
        ),
      );
    },
  );
}

class _ForwardSheetBody extends StatefulWidget {
  final List<ForwardDmTargetPick> targets;
  const _ForwardSheetBody({required this.targets});

  @override
  State<_ForwardSheetBody> createState() => _ForwardSheetBodyState();
}

class _ForwardSheetBodyState extends State<_ForwardSheetBody> {
  ForwardDmTargetPick? _sending;

  Future<void> _select(ForwardDmTargetPick t) async {
    setState(() => _sending = t);
    // Purely an optimistic "sent" confirmation — the actual dispatch runs
    // after this sheet returns the pick to its caller, same as before.
    await Future.delayed(const Duration(milliseconds: 950));
    if (!mounted) return;
    Navigator.pop(context, t);
  }

  @override
  Widget build(BuildContext context) {
    final sending = _sending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    AppL10n.t('Переслать в…'),
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed:
                    sending == null ? () => Navigator.pop(context) : null,
              ),
            ],
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: sending != null
                ? _ForwardSendingConfirmation(
                    key: ValueKey(sending.peerId), target: sending)
                : ListView.separated(
                    key: const ValueKey('list'),
                    itemCount: widget.targets.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      indent: 72,
                      endIndent: 12,
                      color: Theme.of(context)
                          .dividerColor
                          .withValues(alpha: 0.22),
                    ),
                    itemBuilder: (_, i) {
                      final t = widget.targets[i];
                      final cs = Theme.of(context).colorScheme;
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 2,
                        ),
                        leading: AvatarWidget(
                          initials: t.nickname.isNotEmpty
                              ? t.nickname[0].toUpperCase()
                              : '?',
                          color: t.avatarColor,
                          emoji: t.avatarEmoji,
                          imagePath: t.avatarImagePath,
                          size: 48,
                        ),
                        title: Row(
                          children: [
                            if (t.isSavedMessages)
                              Padding(
                                padding:
                                    const EdgeInsets.only(right: 6, top: 1),
                                child: Icon(
                                  Icons.bookmark_outline_rounded,
                                  size: 18,
                                  color:
                                      cs.primary.withValues(alpha: 0.85),
                                ),
                              ),
                            Expanded(
                              child: Text(
                                t.nickname,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                        onTap: () => _select(t),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

/// Avatar morphing into a checkmark inside a filling progress ring — port
/// of skiper-ui's `ShareSheet` send confirmation.
class _ForwardSendingConfirmation extends StatefulWidget {
  final ForwardDmTargetPick target;
  const _ForwardSendingConfirmation({super.key, required this.target});

  @override
  State<_ForwardSendingConfirmation> createState() =>
      _ForwardSendingConfirmationState();
}

class _ForwardSendingConfirmationState
    extends State<_ForwardSendingConfirmation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  )..forward();
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _done = true);
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = widget.target;
    return Center(
      key: const ValueKey('sending'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 76,
            height: 76,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _c,
                  builder: (ctx, _) => CircularProgressIndicator(
                    value: _done ? 1 : _c.value,
                    strokeWidth: 3,
                    color: cs.primary,
                    backgroundColor: cs.primary.withValues(alpha: 0.15),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: anim,
                      child: FadeTransition(opacity: anim, child: child),
                    ),
                    child: _done
                        ? CircleAvatar(
                            key: const ValueKey('check'),
                            backgroundColor: cs.primary,
                            child: Icon(Icons.check_rounded,
                                color: cs.onPrimary),
                          )
                        : AvatarWidget(
                            key: const ValueKey('avatar'),
                            initials: t.nickname.isNotEmpty
                                ? t.nickname[0].toUpperCase()
                                : '?',
                            color: t.avatarColor,
                            emoji: t.avatarEmoji,
                            imagePath: t.avatarImagePath,
                            size: 60,
                          ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(t.nickname,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        ],
      ),
    );
  }
}

/// Grows [_ForwardSheetBody] out of [anchorRect] instead of sliding it up
/// from the bottom — same scale/blur-from-corner language as SpringMenuButton
/// and SpringSearchPalette, driven by the host route's own [animation]
/// (from [showGeneralDialog]) rather than a private AnimationController.
class _ForwardMorphOverlay extends StatelessWidget {
  final Rect anchorRect;
  final List<ForwardDmTargetPick> targets;
  final Animation<double> animation;

  const _ForwardMorphOverlay({
    required this.anchorRect,
    required this.targets,
    required this.animation,
  });

  static const _easeOut = Cubic(0.23, 1, 0.32, 1);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final screen = MediaQuery.sizeOf(context);
    final panelWidth = math.min(340.0, screen.width - 24);
    final panelHeight = math.min(440.0, screen.height * 0.62);

    final growsRight = anchorRect.left + panelWidth <= screen.width - 8;
    final left = growsRight
        ? anchorRect.left.clamp(8.0, screen.width - panelWidth - 8)
        : (anchorRect.right - panelWidth).clamp(8.0, screen.width - panelWidth - 8);

    final growsDown = anchorRect.bottom + panelHeight <= screen.height - 8;
    final top = growsDown
        ? anchorRect.bottom + 8
        : (anchorRect.top - panelHeight - 8).clamp(8.0, screen.height - panelHeight - 8);

    final origin = Alignment(
      growsRight ? -1.0 : 1.0,
      growsDown ? -1.0 : 1.0,
    );

    return AnimatedBuilder(
      animation: animation,
      builder: (ctx, _) {
        final t = _easeOut.transform(animation.value.clamp(0.0, 1.0));
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 2 * t, sigmaY: 2 * t),
                  child: Container(
                      color: Colors.black.withValues(alpha: 0.28 * t)),
                ),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              width: panelWidth,
              height: panelHeight,
              child: Opacity(
                opacity: t,
                child: Transform.scale(
                  scale: 0.9 + 0.1 * t,
                  alignment: origin,
                  child: Material(
                    color: Colors.transparent,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                        child: Container(
                          decoration: BoxDecoration(
                            color:
                                cs.surfaceContainerHigh.withValues(alpha: 0.94),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                                color:
                                    cs.outlineVariant.withValues(alpha: 0.3)),
                          ),
                          child: _ForwardSheetBody(targets: targets),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
