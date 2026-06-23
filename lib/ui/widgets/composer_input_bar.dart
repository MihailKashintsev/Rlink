import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/app_settings.dart';
import '../../services/media_upload_queue.dart';
import '../../services/voice_service.dart';
import 'status_emoji_view.dart';
import 'telegram_media_record_button.dart';

/// Shared chat-style composer (input bar above the keyboard): hold-to-record
/// voice/video, emoji/sticker, media gallery, configurable button order, format
/// strip. Extracted from the chat screen so channels and comments use the
/// identical bar. All behaviour is driven by the callbacks below.
class ComposerInputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool isSending;
  final bool isRecording;
  final bool isVoiceRecordingMode;
  final bool voiceControlsEnabled;
  final bool recordingPaused;
  final bool isHoldVideoStarting;
  final ValueNotifier<double> recordingSecondsNotifier;
  final ValueNotifier<List<double>> recordingWaveformNotifier;
  final String? hintText;

  /// Чат с ИИ: только текст (без медиа и вложений).
  final bool aiTextOnlyComposer;
  final bool allowMediaRecord;
  final bool allowGallery;
  final bool locationActive;
  final VoidCallback onSend;
  final VoidCallback? onLongPressSend;
  final VoidCallback? onPickTodo;
  final VoidCallback? onPickCalendar;
  final VoidCallback onOpenMediaGallery;
  final VoidCallback? onOpenEmojiInsert;
  final VoidCallback? onOpenStickerPicker;
  final VoidCallback onPickSquareVideo;
  final VoidCallback onPickFile;
  final VoidCallback onVoiceHoldStart;
  final Future<void> Function() onVideoHoldStart;
  final Future<void> Function() onHoldReleaseSend;
  final Future<void> Function() onHoldCancelDiscard;
  final Future<void> Function() onVoicePause;
  final Future<void> Function() onVoiceResume;
  final Future<void> Function() onVoicePreview;
  final Future<void> Function() onVoiceTrimLastPart;
  final VoidCallback onLocation;
  final ValueListenable<bool> holdVideoPausedListenable;
  final ValueListenable<bool> voicePausedListenable;
  final void Function(bool locked) onHoldRecordingLockChanged;
  final Future<void> Function() onHoldVideoLockedPauseToggle;

  const ComposerInputBar({
    required this.controller,
    required this.isSending,
    required this.isRecording,
    required this.isVoiceRecordingMode,
    required this.voiceControlsEnabled,
    required this.recordingPaused,
    required this.isHoldVideoStarting,
    required this.recordingSecondsNotifier,
    required this.recordingWaveformNotifier,
    this.hintText,
    this.aiTextOnlyComposer = false,
    this.allowMediaRecord = true,
    this.allowGallery = true,
    required this.locationActive,
    required this.onSend,
    this.onLongPressSend,
    this.onPickTodo,
    this.onPickCalendar,
    required this.onOpenMediaGallery,
    this.onOpenEmojiInsert,
    this.onOpenStickerPicker,
    required this.onPickSquareVideo,
    required this.onPickFile,
    required this.onVoiceHoldStart,
    required this.onVideoHoldStart,
    required this.onHoldReleaseSend,
    required this.onHoldCancelDiscard,
    required this.onVoicePause,
    required this.onVoiceResume,
    required this.onVoicePreview,
    required this.onVoiceTrimLastPart,
    required this.onLocation,
    required this.holdVideoPausedListenable,
    required this.voicePausedListenable,
    required this.onHoldRecordingLockChanged,
    required this.onHoldVideoLockedPauseToggle,
  });

  @override
  State<ComposerInputBar> createState() => ComposerInputBarState();
}

class ComposerInputBarState extends State<ComposerInputBar> {
  final _focusNode = FocusNode();
  late final VoidCallback _controllerListener;

  /// Панель B/I/S… не перекрывает поле — открывается кнопкой при выделении.
  bool _showFormatStrip = false;

  void _onAppSettingsChanged() {
    if (mounted) setState(() {});
  }

  List<Map<String, dynamic>> get _buttonConfig =>
      AppSettings.instance.inputBarButtonConfig;

  bool get _hasConfiguredRecordButton =>
      _buttonConfig.any((b) => b['id'] == 'voice_video_square');

  List<Widget> _buildButtonsInOrder(ColorScheme cs, {required bool leftSide}) {
    final buttons = <Widget>[];

    for (final buttonConfig in _buttonConfig) {
      final buttonId = buttonConfig['id'] as String;
      final side = buttonConfig['side'] as String;

      if (side != (leftSide ? 'left' : 'right')) continue;

      switch (buttonId) {
        case 'voice_video_square':
          if (widget.allowMediaRecord) {
            buttons.add(_buildVoiceVideoButton(cs));
          }
          break;
        case 'send_button':
          // Send button is handled separately in the expanded section, skip here
          break;
        case 'emoji_stickers':
          if (widget.onOpenEmojiInsert != null ||
              widget.onOpenStickerPicker != null) {
            buttons.add(_buildEmojiButton(cs));
          }
          break;
        case 'media_menu':
          if (widget.allowGallery) {
            buttons.add(_buildMediaButton(cs));
          }
          break;
      }
    }

    return buttons;
  }

  Widget _buildVoiceVideoButton(ColorScheme cs) {
    return TelegramMediaRecordButton(
      isSending: widget.isSending,
      isRecording: widget.isRecording,
      isHoldVideoStarting: widget.isHoldVideoStarting,
      colorScheme: cs,
      onVoiceHoldStart: widget.onVoiceHoldStart,
      onVideoHoldStart: widget.onVideoHoldStart,
      onHoldReleaseSend: widget.onHoldReleaseSend,
      onHoldCancelDiscard: widget.onHoldCancelDiscard,
      onHoldLockChanged: widget.onHoldRecordingLockChanged,
      onLockedVideoPauseToggle: widget.onHoldVideoLockedPauseToggle,
      lockedVideoPausedListenable: widget.holdVideoPausedListenable,
      onLockedVoicePauseToggle: widget.onVoicePause,
      lockedVoicePausedListenable: widget.voicePausedListenable,
      onLockedVoiceTrimLastPart: widget.onVoiceTrimLastPart,
    );
  }

  Widget _buildEmojiButton(ColorScheme cs) {
    return IconButton(
      onPressed: widget.isSending ? null : _openEmojiOrStickerPicker,
      icon: Icon(
        Icons.emoji_emotions_outlined,
        color: widget.isSending
            ? cs.onSurface.withValues(alpha: 0.3)
            : cs.onSurfaceVariant,
        size: 24,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      tooltip: 'Эмодзи',
    );
  }

  Widget _buildMediaButton(ColorScheme cs) {
    return IconButton(
      onPressed: widget.isSending || !widget.allowGallery
          ? null
          : widget.onOpenMediaGallery,
      icon: Icon(
        Icons.photo_library_outlined,
        color: widget.isSending || !widget.allowGallery
            ? cs.onSurface.withValues(alpha: 0.3)
            : cs.onSurfaceVariant,
        size: 24,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      tooltip: 'Галерея и вложения',
    );
  }

  @override
  void initState() {
    super.initState();
    AppSettings.instance.addListener(_onAppSettingsChanged);
    _controllerListener = () {
      if (mounted) {
        setState(() {
          final sel = widget.controller.selection;
          if (!sel.isValid || sel.isCollapsed) {
            _showFormatStrip = false;
          }
        });
      }
    };
    widget.controller.addListener(_controllerListener);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onAppSettingsChanged);
    widget.controller.removeListener(_controllerListener);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ComposerInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_controllerListener);
      widget.controller.addListener(_controllerListener);
      final sel = widget.controller.selection;
      if (!sel.isValid || sel.isCollapsed) {
        _showFormatStrip = false;
      }
    }
  }

  void _wrapSelection(String prefix, String suffix) {
    final sel = widget.controller.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    final text = widget.controller.text;
    final selected = text.substring(sel.start, sel.end);
    final newText =
        text.replaceRange(sel.start, sel.end, '$prefix$selected$suffix');
    final newOffset = sel.end + prefix.length + suffix.length;
    widget.controller.value = widget.controller.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
    );
  }

  Future<void> _openEmojiOrStickerPicker() async {
    if (widget.isSending) return;
    final openEmoji = widget.onOpenEmojiInsert;
    if (openEmoji != null) {
      openEmoji();
    } else {
      final openSticker = widget.onOpenStickerPicker;
      if (openSticker != null) {
        openSticker();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasText = widget.controller.text.trim().isNotEmpty;

    final cs = Theme.of(context).colorScheme;
    final sel = widget.controller.selection;
    final hasSelection = sel.isValid && sel.baseOffset != sel.extentOffset;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: cs.surface,
          border:
              Border(top: BorderSide(color: cs.outline.withValues(alpha: 0.3))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasSelection && _showFormatStrip)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    _FmtBtn(
                        label: 'B',
                        bold: true,
                        onTap: () => _wrapSelection('**', '**')),
                    _FmtBtn(
                        label: 'I',
                        italic: true,
                        onTap: () => _wrapSelection('_', '_')),
                    _FmtBtn(
                        label: 'S',
                        strikethrough: true,
                        onTap: () => _wrapSelection('~~', '~~')),
                    _FmtBtn(
                        label: 'U',
                        underline: true,
                        onTap: () => _wrapSelection('__', '__')),
                    _FmtBtn(
                        label: '||', onTap: () => _wrapSelection('||', '||')),
                  ],
                ),
              ),
            Row(children: [
              if (hasSelection)
                IconButton(
                  onPressed: () =>
                      setState(() => _showFormatStrip = !_showFormatStrip),
                  icon: Icon(
                    Icons.text_fields_rounded,
                    color: _showFormatStrip ? cs.primary : cs.onSurfaceVariant,
                    size: 22,
                  ),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  tooltip: _showFormatStrip
                      ? 'Скрыть формат'
                      : 'Формат выделенного текста',
                ),
              if (!widget.aiTextOnlyComposer) ...[
                ..._buildButtonsInOrder(cs, leftSide: true),
                const SizedBox(width: 2),
              ],
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: widget.isVoiceRecordingMode
                      ? Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          child: Row(
                            children: [
                              GestureDetector(
                                onTap: widget.voiceControlsEnabled
                                    ? (widget.recordingPaused
                                        ? () =>
                                            unawaited(widget.onVoiceResume())
                                        : () =>
                                            unawaited(widget.onVoicePause()))
                                    : null,
                                child: Icon(
                                  widget.recordingPaused
                                      ? Icons.play_circle_fill_rounded
                                      : Icons.pause_circle_filled_rounded,
                                  color: widget.voiceControlsEnabled
                                      ? cs.primary
                                      : cs.onSurfaceVariant
                                          .withValues(alpha: 0.45),
                                  size: 30,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: ValueListenableBuilder<List<double>>(
                                  valueListenable:
                                      widget.recordingWaveformNotifier,
                                  builder: (_, bars, __) {
                                    return SizedBox(
                                      height: 36,
                                      child: CustomPaint(
                                        painter: _LiveRecordingWaveformPainter(
                                          bars: bars,
                                          color: cs.primary,
                                          paused: widget.recordingPaused,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              ValueListenableBuilder<double>(
                                valueListenable:
                                    widget.recordingSecondsNotifier,
                                builder: (_, secs, __) {
                                  final mm =
                                      (secs ~/ 60).toString().padLeft(2, '0');
                                  final ss = (secs.floor() % 60)
                                      .toString()
                                      .padLeft(2, '0');
                                  return Text(
                                    '$mm:$ss',
                                    style: TextStyle(
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                      fontWeight: FontWeight.w700,
                                      color: cs.onSurface,
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(width: 6),
                              if (widget.voiceControlsEnabled &&
                                  widget.recordingPaused)
                                ValueListenableBuilder<String?>(
                                  valueListenable:
                                      VoiceService.instance.currentlyPlaying,
                                  builder: (_, playing, __) {
                                    final isPreviewing =
                                        playing != null && playing.isNotEmpty;
                                    return GestureDetector(
                                      onTap: () => unawaited(
                                        widget.onVoicePreview(),
                                      ),
                                      child: Icon(
                                        isPreviewing
                                            ? Icons.stop_circle_outlined
                                            : Icons.play_circle_outline,
                                        color: cs.primary,
                                        size: 24,
                                      ),
                                    );
                                  },
                                ),
                              if (widget.voiceControlsEnabled &&
                                  widget.recordingPaused)
                                const SizedBox(width: 6),
                              GestureDetector(
                                onTap: widget.voiceControlsEnabled &&
                                        widget.recordingPaused
                                    ? () => unawaited(
                                          widget.onVoiceTrimLastPart(),
                                        )
                                    : null,
                                child: Icon(
                                  Icons.content_cut_rounded,
                                  color: widget.recordingPaused
                                      ? cs.secondary
                                      : cs.onSurfaceVariant
                                          .withValues(alpha: 0.4),
                                  size: 22,
                                ),
                              ),
                              if (!widget.voiceControlsEnabled) ...[
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.lock_outline_rounded,
                                  size: 16,
                                  color: cs.onSurfaceVariant
                                      .withValues(alpha: 0.55),
                                ),
                              ],
                            ],
                          ),
                        )
                      : ValueListenableBuilder<double>(
                          valueListenable: widget.recordingSecondsNotifier,
                          builder: (_, secs, __) {
                            final s = secs.floor();
                            final t = ((secs % 1) * 10).floor();
                            final sendOnEnter =
                                AppSettings.instance.sendOnEnter;
                            final hasShortcode =
                                widget.controller.text.contains(':');
                            final textStyle = TextStyle(
                              fontSize: 15,
                              color: hasShortcode
                                  ? Colors.transparent
                                  : cs.onSurface,
                            );
                            return Stack(
                              children: [
                                TextField(
                                  controller: widget.controller,
                                  focusNode: _focusNode,
                                  onTapOutside: (_) => _focusNode.unfocus(),
                                  enabled: true,
                                  maxLines: sendOnEnter ? 1 : 4,
                                  minLines: 1,
                                  textInputAction: sendOnEnter
                                      ? TextInputAction.send
                                      : TextInputAction.newline,
                                  onSubmitted: sendOnEnter
                                      ? (_) {
                                          if (!widget.isSending &&
                                              !widget.isRecording) {
                                            widget.onSend();
                                          }
                                        }
                                      : null,
                                  style: textStyle,
                                  decoration: InputDecoration(
                                    hintText: widget.isRecording
                                        ? 'Запись... ${s}s.$t'
                                        : (widget.hintText ?? 'Сообщение...'),
                                    hintStyle: TextStyle(
                                        color: cs.onSurfaceVariant
                                            .withValues(alpha: 0.6)),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 10),
                                  ),
                                ),
                                if (hasShortcode)
                                  IgnorePointer(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 10),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: CustomEmojiInlineText(
                                          text: widget.controller.text,
                                          maxLines: sendOnEnter ? 1 : 4,
                                          overflow: TextOverflow.clip,
                                          style: TextStyle(
                                            fontSize: 15,
                                            color: cs.onSurface,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(width: 8),
              ..._buildButtonsInOrder(cs, leftSide: false),
              if (!widget.aiTextOnlyComposer &&
                  widget.allowMediaRecord &&
                  !_hasConfiguredRecordButton) ...[
                TelegramMediaRecordButton(
                  isSending: widget.isSending,
                  isRecording: widget.isRecording,
                  isHoldVideoStarting: widget.isHoldVideoStarting,
                  colorScheme: cs,
                  onVoiceHoldStart: widget.onVoiceHoldStart,
                  onVideoHoldStart: widget.onVideoHoldStart,
                  onHoldReleaseSend: widget.onHoldReleaseSend,
                  onHoldCancelDiscard: widget.onHoldCancelDiscard,
                  onHoldLockChanged: widget.onHoldRecordingLockChanged,
                  onLockedVideoPauseToggle: widget.onHoldVideoLockedPauseToggle,
                  lockedVideoPausedListenable: widget.holdVideoPausedListenable,
                  onLockedVoicePauseToggle: widget.onVoicePause,
                  lockedVoicePausedListenable: widget.voicePausedListenable,
                  onLockedVoiceTrimLastPart: widget.onVoiceTrimLastPart,
                ),
                const SizedBox(width: 8),
              ],
              if (hasText || widget.isSending)
                GestureDetector(
                  onTap: widget.isSending || widget.isRecording
                      ? null
                      : widget.onSend,
                  onLongPress: (widget.onLongPressSend == null ||
                          !hasText ||
                          widget.isSending ||
                          widget.isRecording)
                      ? null
                      : widget.onLongPressSend,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: (widget.isSending || widget.isRecording)
                          ? cs.onSurface.withValues(alpha: 0.3)
                          : cs.primary,
                      shape: BoxShape.circle,
                    ),
                    child: widget.isSending
                        ? Padding(
                            padding: const EdgeInsets.all(10),
                            child: ValueListenableBuilder<Map<String, double>>(
                              valueListenable:
                                  MediaUploadQueue.instance.progressMap,
                              builder: (_, map, __) {
                                final p = map.values.isEmpty
                                    ? null
                                    : map.values
                                        .reduce((a, b) => a > b ? a : b);
                                return Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    CircularProgressIndicator(
                                      value: (p != null && p > 0.02) ? p : null,
                                      strokeWidth: 2.4,
                                      color: cs.onPrimary,
                                      backgroundColor:
                                          cs.onPrimary.withValues(alpha: 0.25),
                                    ),
                                    if (p != null && p > 0.02)
                                      Text(
                                        '${(p * 100).round()}',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w700,
                                          color: cs.onPrimary,
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          )
                        : Icon(Icons.send_rounded,
                            color: cs.onPrimary, size: 20),
                  ),
                ),
            ]),
          ],
        ),
      ),
    );
  }
}

class _LiveRecordingWaveformPainter extends CustomPainter {
  final List<double> bars;
  final Color color;
  final bool paused;

  const _LiveRecordingWaveformPainter({
    required this.bars,
    required this.color,
    required this.paused,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..style = PaintingStyle.fill
      ..color = paused ? color.withValues(alpha: 0.35) : color;
    final baseY = size.height / 2;
    final count = bars.isEmpty ? 24 : bars.length;
    const gap = 2.0;
    final barW = ((size.width - (count - 1) * gap) / count).clamp(1.0, 4.0);
    final maxH = size.height * 0.9;
    for (var i = 0; i < count; i++) {
      final amp = i < bars.length ? bars[i].clamp(0.05, 1.0) : 0.05;
      final h = (maxH * amp).clamp(2.0, maxH);
      final x = i * (barW + gap);
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, baseY - h / 2, barW, h),
        const Radius.circular(2),
      );
      canvas.drawRRect(r, p);
    }
  }

  @override
  bool shouldRepaint(covariant _LiveRecordingWaveformPainter oldDelegate) {
    return oldDelegate.bars != bars ||
        oldDelegate.color != color ||
        oldDelegate.paused != paused;
  }
}

class _FmtBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool bold;
  final bool italic;
  final bool strikethrough;
  final bool underline;

  const _FmtBtn({
    required this.label,
    required this.onTap,
    this.bold = false,
    this.italic = false,
    this.strikethrough = false,
    this.underline = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            fontStyle: italic ? FontStyle.italic : FontStyle.normal,
            decoration: strikethrough
                ? TextDecoration.lineThrough
                : underline
                    ? TextDecoration.underline
                    : null,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}

// ── Stranger Banner Action Button ─────────────────────────────
