import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/app_settings.dart';
import '../design/rlink_design.dart';
import '../../services/media_upload_queue.dart';
import '../../services/voice_service.dart';
import 'avatar_widget.dart';
import 'status_emoji_view.dart';
import 'telegram_media_record_button.dart';
import 'translate_action.dart';
import 'unified_emoji_picker.dart';

/// A person suggested in the @-mention picker. [id] is the public-key hex that
/// gets inserted into the text as the `&hex` mention token.
class MentionCandidate {
  final String id;
  final String title;
  final String username;
  final String initials;
  final int avatarColor;
  final String avatarEmoji;
  final String? avatarImagePath;
  const MentionCandidate({
    required this.id,
    required this.title,
    required this.username,
    required this.initials,
    required this.avatarColor,
    required this.avatarEmoji,
    this.avatarImagePath,
  });
}

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

  /// When provided, typing `@` opens a contact picker above the input.
  final List<MentionCandidate> Function()? mentionCandidates;

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
    this.mentionCandidates,
  });

  @override
  State<ComposerInputBar> createState() => ComposerInputBarState();
}

class ComposerInputBarState extends State<ComposerInputBar> {
  final _focusNode = FocusNode();
  late final VoidCallback _controllerListener;

  /// Панель B/I/S… не перекрывает поле — открывается кнопкой при выделении.

  // @-mention picker state. Active when the cursor sits inside a `@token`.
  String? _mentionQuery;
  int _mentionStart = 0;

  void _updateMention() {
    if (widget.mentionCandidates == null) {
      _mentionQuery = null;
      return;
    }
    final sel = widget.controller.selection;
    final text = widget.controller.text;
    if (!sel.isValid || !sel.isCollapsed) {
      _mentionQuery = null;
      return;
    }
    final cursor = sel.baseOffset.clamp(0, text.length);
    int at = -1;
    for (int i = cursor - 1; i >= 0; i--) {
      final ch = text[i];
      if (ch == '@') {
        if (i == 0 || RegExp(r'\s').hasMatch(text[i - 1])) at = i;
        break;
      }
      if (RegExp(r'[\s&]').hasMatch(ch)) break;
    }
    if (at < 0) {
      _mentionQuery = null;
      return;
    }
    _mentionQuery = text.substring(at + 1, cursor);
    _mentionStart = at;
  }

  List<MentionCandidate> get _filteredMentions {
    final all = widget.mentionCandidates?.call() ?? const <MentionCandidate>[];
    final q = (_mentionQuery ?? '').toLowerCase();
    final list = q.isEmpty
        ? all
        : all
            .where((c) =>
                c.title.toLowerCase().contains(q) ||
                c.username.toLowerCase().contains(q))
            .toList();
    return list.take(30).toList();
  }

  void _applyMention(MentionCandidate c) {
    final text = widget.controller.text;
    final cursor =
        widget.controller.selection.baseOffset.clamp(0, text.length);
    final start = _mentionStart.clamp(0, text.length);
    final insert = '&${c.id} ';
    final nt = text.replaceRange(start, cursor, insert);
    widget.controller.value = TextEditingValue(
      text: nt,
      selection: TextSelection.collapsed(
          offset: (start + insert.length).clamp(0, nt.length)),
    );
    setState(() => _mentionQuery = null);
  }

  Widget _buildMentionList(ColorScheme cs) {
    final items = _filteredMentions;
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final c = items[i];
          return ListTile(
            dense: true,
            leading: AvatarWidget(
              initials: c.initials,
              color: c.avatarColor,
              emoji: c.avatarEmoji,
              imagePath: c.avatarImagePath,
              size: 36,
            ),
            title:
                Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: c.username.isNotEmpty
                ? Text('@${c.username}',
                    maxLines: 1, overflow: TextOverflow.ellipsis)
                : null,
            onTap: () => _applyMention(c),
          );
        },
      ),
    );
  }

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
          // Hide the record button once there's text — the send button takes
          // its place and the field gets the freed width.
          if (widget.allowMediaRecord &&
              widget.controller.text.trim().isEmpty) {
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
          _updateMention();
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

  /// «Супер-режим»: текст перерос поле — предлагаем открыть его на весь экран.
  bool get _isLongText {
    final t = widget.controller.text;
    if (t.isEmpty) return false;
    return '\n'.allMatches(t).length >= 3 || t.length > 140;
  }

  /// Полноэкранный редактор для длинного сообщения. Делит тот же контроллер,
  /// поэтому текст остаётся синхронным; сверху — кнопка отправки.
  Future<void> _openFullscreenEditor() async {
    _focusNode.unfocus();
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (ctx) => _FullscreenComposerEditor(
          controller: widget.controller,
          hintText: widget.hintText ?? 'Сообщение...',
          isSending: widget.isSending,
          onSend: () {
            Navigator.of(ctx).pop();
            widget.onSend();
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant ComposerInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_controllerListener);
      widget.controller.addListener(_controllerListener);
    }
  }

  bool get _hasSelection {
    final s = widget.controller.selection;
    return s.isValid && !s.isCollapsed;
  }

  /// Панель форматирования выделения — показывается прямо над полем ввода, когда
  /// есть выделение. Работает в любом браузере (в т.ч. iOS Safari, где нативное
  /// меню выделения перекрывает наше contextMenuBuilder).
  Widget _buildFormatBar(ColorScheme cs) {
    Widget btn(String label, String p, String s, {TextStyle? style}) {
      return InkWell(
        onTap: () => _wrapSelection(p, s),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 40,
          height: 34,
          alignment: Alignment.center,
          child: Text(label,
              style: style ??
                  TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          btn('Ж', '**', '**',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface)),
          btn('К', '_', '_',
              style: TextStyle(
                  fontSize: 16,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface)),
          btn('S', '~~', '~~',
              style: TextStyle(
                  fontSize: 15,
                  decoration: TextDecoration.lineThrough,
                  color: cs.onSurface)),
          btn('U', '__', '__',
              style: TextStyle(
                  fontSize: 15,
                  decoration: TextDecoration.underline,
                  color: cs.onSurface)),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Скрытый',
            icon: Icon(Icons.visibility_off_outlined,
                size: 20, color: cs.onSurface),
            onPressed: () => _wrapSelection('||', '||'),
          ),
          const Spacer(),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Перевести',
            icon: Icon(Icons.translate, size: 20, color: cs.primary),
            onPressed: () {
              final sel = widget.controller.selection;
              if (sel.isValid && !sel.isCollapsed) {
                showTranslateResult(
                    context, sel.textInside(widget.controller.text));
              }
            },
          ),
        ],
      ),
    );
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

  /// Selection toolbar (shown on select / long-press of the selection) with the
  /// system items + formatting actions — replaces the old format-toggle button.
  Widget _formatContextMenu(
      BuildContext context, EditableTextState editableState) {
    final items = List<ContextMenuButtonItem>.from(
        editableState.contextMenuButtonItems);
    final sel = widget.controller.selection;
    if (sel.isValid && !sel.isCollapsed) {
      void fmt(String p, String s) {
        _wrapSelection(p, s);
        editableState.hideToolbar();
      }

      final selectedText = sel.textInside(widget.controller.text);
      items.addAll([
        ContextMenuButtonItem(
            label: 'Перевести',
            onPressed: () {
              editableState.hideToolbar();
              showTranslateResult(context, selectedText);
            }),
        ContextMenuButtonItem(
            label: 'Жирный', onPressed: () => fmt('**', '**')),
        ContextMenuButtonItem(label: 'Курсив', onPressed: () => fmt('_', '_')),
        ContextMenuButtonItem(
            label: 'Зачёркнутый', onPressed: () => fmt('~~', '~~')),
        ContextMenuButtonItem(
            label: 'Подчёркнутый', onPressed: () => fmt('__', '__')),
        ContextMenuButtonItem(
            label: 'Скрытый', onPressed: () => fmt('||', '||')),
      ]);
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableState.contextMenuAnchors,
      buttonItems: items,
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
            if (_hasSelection && !widget.aiTextOnlyComposer) _buildFormatBar(cs),
            if (_mentionQuery != null && _filteredMentions.isNotEmpty)
              _buildMentionList(cs),
            Row(children: [
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
                                  contextMenuBuilder: _formatContextMenu,
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
                                if (!sendOnEnter &&
                                    !widget.isRecording &&
                                    _isLongText)
                                  Positioned(
                                    top: 2,
                                    right: 2,
                                    child: Material(
                                      color: cs.surfaceContainerHighest
                                          .withValues(alpha: 0.9),
                                      shape: const CircleBorder(),
                                      clipBehavior: Clip.antiAlias,
                                      child: InkWell(
                                        onTap: _openFullscreenEditor,
                                        child: Padding(
                                          padding: const EdgeInsets.all(5),
                                          child: Icon(
                                            Icons.open_in_full_rounded,
                                            size: 16,
                                            color: cs.onSurfaceVariant,
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
                  !_hasConfiguredRecordButton &&
                  !hasText) ...[
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
                    decoration: (widget.isSending || widget.isRecording)
                        ? BoxDecoration(
                            color: cs.onSurface.withValues(alpha: 0.3),
                            shape: BoxShape.circle,
                          )
                        : RlinkDesign.on
                            ? BoxDecoration(
                                gradient: RlinkDesign.accentGradient(cs),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: RlinkDesign.accent(cs)
                                        .withValues(alpha: 0.45),
                                    blurRadius: 14,
                                    spreadRadius: 1,
                                  ),
                                ],
                              )
                            : BoxDecoration(
                                color: cs.primary,
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


/// Полноэкранный редактор длинного сообщения. Шарит контроллер с композером,
/// поэтому текст остаётся синхронным; кнопка отправки — сверху справа.
class _FullscreenComposerEditor extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  final bool isSending;
  final VoidCallback onSend;

  const _FullscreenComposerEditor({
    required this.controller,
    required this.hintText,
    required this.isSending,
    required this.onSend,
  });

  @override
  State<_FullscreenComposerEditor> createState() =>
      _FullscreenComposerEditorState();
}

class _FullscreenComposerEditorState extends State<_FullscreenComposerEditor> {
  final _focusNode = FocusNode();

  // Lightweight undo/redo over the shared controller's value.
  final _undo = <TextEditingValue>[];
  final _redo = <TextEditingValue>[];
  late TextEditingValue _last;
  bool _applyingHistory = false;
  bool _showEmoji = false;

  TextEditingController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _last = _c.value;
    _c.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _onChanged() {
    if (!_applyingHistory && _c.text != _last.text) {
      _undo.add(_last);
      if (_undo.length > 200) _undo.removeAt(0);
      _redo.clear();
    }
    _last = _c.value;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c.removeListener(_onChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _apply(String text, int caret) {
    _applyingHistory = false;
    _c.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret.clamp(0, text.length)),
    );
    _focusNode.requestFocus();
  }

  void _undoAction() {
    if (_undo.isEmpty) return;
    _applyingHistory = true;
    _redo.add(_c.value);
    final v = _undo.removeLast();
    _c.value = v;
    _last = v;
    _applyingHistory = false;
    if (mounted) setState(() {});
  }

  void _redoAction() {
    if (_redo.isEmpty) return;
    _applyingHistory = true;
    _undo.add(_c.value);
    final v = _redo.removeLast();
    _c.value = v;
    _last = v;
    _applyingHistory = false;
    if (mounted) setState(() {});
  }

  /// Wrap the selection, or drop paired markers at the caret and land between
  /// them so the next typing is formatted (tap the same tool again / move past
  /// the marker to stop — "нажать жирный → жирный, продолжить без").
  void _wrap(String prefix, String suffix) {
    final sel = _c.selection;
    final text = _c.text;
    if (sel.isValid && !sel.isCollapsed) {
      final inner = text.substring(sel.start, sel.end);
      _apply(text.replaceRange(sel.start, sel.end, '$prefix$inner$suffix'),
          sel.end + prefix.length + suffix.length);
    } else {
      final at = sel.isValid ? sel.start : text.length;
      _apply(text.replaceRange(at, at, '$prefix$suffix'), at + prefix.length);
    }
  }

  void _insert(String s, {int caretBack = 0}) {
    final sel = _c.selection;
    final text = _c.text;
    final at = sel.isValid ? sel.start : text.length;
    final end = sel.isValid && !sel.isCollapsed ? sel.end : at;
    _apply(text.replaceRange(at, end, s), at + s.length - caretBack);
  }

  void _insertLinePrefix(String prefix) {
    final sel = _c.selection;
    final text = _c.text;
    final at = sel.isValid ? sel.start : text.length;
    var lineStart = at;
    while (lineStart > 0 && text[lineStart - 1] != '\n') {
      lineStart--;
    }
    _apply(text.replaceRange(lineStart, lineStart, prefix),
        at + prefix.length);
  }

  void _insertTable() {
    final needsNl = _c.selection.baseOffset > 0 &&
        _c.text.isNotEmpty &&
        !_c.text
            .substring(0, _c.selection.baseOffset.clamp(0, _c.text.length))
            .endsWith('\n');
    const table = '| Колонка | Колонка |\n| --- | --- |\n|  |  |\n';
    _insert('${needsNl ? '\n' : ''}$table');
  }

  /// Strip common markdown markers from the selection (or the whole text).
  void _clearFormatting() {
    final sel = _c.selection;
    final full = _c.text;
    final start = (sel.isValid && !sel.isCollapsed) ? sel.start : 0;
    final end = (sel.isValid && !sel.isCollapsed) ? sel.end : full.length;
    var seg = full.substring(start, end);
    for (final m in ['**', '__', '~~', '||', '`']) {
      seg = seg.replaceAll(m, '');
    }
    seg = seg.replaceAll(RegExp(r'(^|\n)> ?'), r'$1');
    _apply(full.replaceRange(start, end, seg), start + seg.length);
  }

  void _openEmoji() {
    FocusScope.of(context).unfocus();
    setState(() => _showEmoji = true);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canSend = _c.text.trim().isNotEmpty && !widget.isSending;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Сообщение'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: canSend ? widget.onSend : null,
              icon: const Icon(Icons.send_rounded, size: 18),
              label: const Text('Отправить'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                controller: _c,
                focusNode: _focusNode,
                autofocus: true,
                maxLines: null,
                expands: true,
                keyboardType: TextInputType.multiline,
                textAlignVertical: TextAlignVertical.top,
                style:
                    TextStyle(fontSize: 16, color: cs.onSurface, height: 1.35),
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: TextStyle(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
                  border: InputBorder.none,
                ),
                onTap: () {
                  if (_showEmoji) setState(() => _showEmoji = false);
                },
              ),
            ),
          ),
          _toolbar(cs),
          if (_showEmoji)
            SizedBox(
              height: 280,
              child: UnifiedEmojiPicker(
                onSelected: (v) => _insert(v),
              ),
            ),
        ],
      ),
    );
  }

  Widget _toolbar(ColorScheme cs) {
    Widget btn(IconData icon, VoidCallback? onTap, {String? tip}) {
      final w = IconButton(
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, size: 21),
        color: onTap == null ? cs.onSurfaceVariant.withValues(alpha: 0.35) : null,
        onPressed: onTap,
      );
      return tip == null ? w : Tooltip(message: tip, child: w);
    }

    Widget textBtn(String label, VoidCallback onTap,
        {FontWeight? weight, FontStyle? style, bool strike = false}) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 40,
          alignment: Alignment.center,
          child: Text(label,
              style: TextStyle(
                fontSize: 17,
                fontWeight: weight,
                fontStyle: style,
                decoration:
                    strike ? TextDecoration.lineThrough : TextDecoration.none,
                color: cs.onSurface,
              )),
        ),
      );
    }

    return Material(
      color: cs.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            children: [
              btn(Icons.undo_rounded, _undo.isEmpty ? null : _undoAction,
                  tip: 'Отменить'),
              btn(Icons.redo_rounded, _redo.isEmpty ? null : _redoAction,
                  tip: 'Вернуть'),
              _sep(cs),
              textBtn('B', () => _wrap('**', '**'), weight: FontWeight.w800),
              textBtn('I', () => _wrap('_', '_'), style: FontStyle.italic),
              textBtn('U', () => _wrap('__', '__')),
              textBtn('S', () => _wrap('~~', '~~'), strike: true),
              btn(Icons.code_rounded, () => _wrap('`', '`'), tip: 'Моно'),
              btn(Icons.visibility_off_outlined, () => _wrap('||', '||'),
                  tip: 'Спойлер'),
              btn(Icons.format_quote_rounded, () => _insertLinePrefix('> '),
                  tip: 'Цитата'),
              btn(Icons.format_list_bulleted_rounded,
                  () => _insertLinePrefix('• '),
                  tip: 'Список'),
              btn(Icons.table_chart_outlined, _insertTable, tip: 'Таблица'),
              btn(Icons.emoji_emotions_outlined, _openEmoji, tip: 'Эмодзи'),
              _sep(cs),
              btn(Icons.format_clear_rounded, _clearFormatting,
                  tip: 'Убрать форматирование'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sep(ColorScheme cs) => Center(
        child: Container(
          width: 1,
          height: 22,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          color: cs.outlineVariant,
        ),
      );
}

// ── Stranger Banner Action Button ─────────────────────────────
