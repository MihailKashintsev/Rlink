import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
import 'package:flutter/material.dart';
import '../../l10n/app_l10n.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../utils/web_file_store.dart';

import '../../models/chat_message.dart';
import '../../services/ble_service.dart';
import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import '../../services/gossip_router.dart';
import '../../services/relay_service.dart';
import '../../services/story_service.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/reactions.dart';
import '../widgets/story_strokes_painter.dart';

/// Full-screen story viewer with animated progress bar (Telegram/Instagram-style).
class StoryViewerScreen extends StatefulWidget {
  final String authorId;
  final String authorName;
  final List<StoryItem> stories;
  final int initialIndex;

  const StoryViewerScreen({
    super.key,
    required this.authorId,
    required this.authorName,
    required this.stories,
    this.initialIndex = 0,
  });

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen>
    with SingleTickerProviderStateMixin {
  late int _index;
  late List<StoryItem> _stories;
  late AnimationController _progressCtrl;
  Timer? _timer;
  VideoPlayerController? _videoCtrl;

  final _uuid = const Uuid();
  bool _sendingReply = false;

  // Author avatar (looked up once for the redesigned header).
  int _authorColor = 0xFF5C6BC0;
  String _authorEmoji = '';
  String? _authorImage;

  static const _storyDuration = Duration(seconds: 5);

  Future<void> _showStoryReactionLimitHint() async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('Лимит реакций на историю достигнут'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _trySendStoryReaction(String emoji) async {
    final story = _stories[_index];
    final myId = CryptoService.instance.publicKeyHex;
    final hadBefore = story.hasReaction(emoji, myId);
    final totalBefore = story.totalReactions;
    final mineBefore = story.reactionsBy(myId);
    final updated = StoryService.instance.toggleReaction(story.id, emoji, myId);
    if (updated == null) return;
    final hasAfter = updated.hasReaction(emoji, myId);
    final blockedAdd = !hadBefore &&
        !hasAfter &&
        (totalBefore >= kMaxStoryReactionsTotal ||
            mineBefore >= kMaxStoryDistinctReactionsPerUser);
    if (blockedAdd) {
      await _showStoryReactionLimitHint();
      return;
    }
    await GossipRouter.instance.sendReactionExt(
      kind: 'story',
      targetId: story.id,
      emoji: emoji,
      fromId: myId,
    );
  }

  @override
  void initState() {
    super.initState();
    _stories = List.from(widget.stories);
    _index = widget.initialIndex.clamp(0, (_stories.length - 1).clamp(0, 999));
    _progressCtrl = AnimationController(
      vsync: this,
      duration: _storyDuration,
    );
    _startStory();
    StoryService.instance.version.addListener(_onStoryUpdate);
    _loadAuthorAvatar();
  }

  Future<void> _loadAuthorAvatar() async {
    final c = await ChatStorageService.instance.getContact(widget.authorId);
    if (!mounted || c == null) return;
    setState(() {
      _authorColor = c.avatarColor;
      _authorEmoji = c.avatarEmoji;
      _authorImage = c.avatarImagePath;
    });
  }

  /// Opens a bottom sheet with a text field to reply privately to the author
  /// (sent as a normal encrypted DM). Self-contained focus scope avoids any
  /// gesture conflict with the story canvas.
  Future<void> _openReplySheet() async {
    final myId = CryptoService.instance.publicKeyHex;
    if (_stories[_index].authorId == myId) return;
    _pauseStory();
    final ctrl = TextEditingController();
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 14,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: ctrl,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                style: const TextStyle(color: Colors.white),
                textInputAction: TextInputAction.send,
                onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
                decoration: InputDecoration(
                  hintText: 'Ответить ${widget.authorName}…',
                  hintStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.1),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              icon: const Icon(Icons.send_rounded),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (text != null && text.isNotEmpty) {
      await _sendStoryReply(text);
    }
    if (mounted) _resumeStory();
  }

  Future<void> _sendStoryReply(String text) async {
    if (text.isEmpty || _sendingReply) return;
    final story = _stories[_index];
    final myId = CryptoService.instance.publicKeyHex;
    final target = story.authorId;
    if (target == myId) return;
    setState(() => _sendingReply = true);
    final body = '↩️ Ответ на историю: $text';
    try {
      final msgId = _uuid.v4();
      var x25519Key = BleService.instance.getPeerX25519Key(target) ??
          RelayService.instance.getPeerX25519Key(target);
      x25519Key ??=
          (await ChatStorageService.instance.getContact(target))?.x25519Key;
      final msg = ChatMessage(
        id: msgId,
        peerId: target,
        text: body,
        isOutgoing: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sending,
      );
      await ChatStorageService.instance.saveMessage(msg);
      if (x25519Key != null && x25519Key.isNotEmpty) {
        final enc = await CryptoService.instance.encryptMessage(
          plaintext: body,
          recipientX25519KeyBase64: x25519Key,
        );
        await GossipRouter.instance.sendEncryptedMessage(
          encrypted: enc,
          senderId: myId,
          recipientId: target,
          messageId: msgId,
        );
        await ChatStorageService.instance
            .updateMessageStatusPreserveDelivered(msgId, MessageStatus.sent);
      } else {
        await ChatStorageService.instance
            .updateMessageStatusPreserveDelivered(msgId, MessageStatus.failed);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Ответ отправлен'),
              duration: Duration(seconds: 2)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось отправить ответ')),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingReply = false);
    }
  }

  void _onStoryUpdate() {
    if (!mounted) return;
    final updated = StoryService.instance.storiesFor(widget.authorId);
    if (updated.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _stories = updated;
      if (_index >= _stories.length) {
        _index = _stories.length - 1;
        _startStory();
      }
    });
  }

  void _pauseStory() {
    _timer?.cancel();
    _progressCtrl.stop();
  }

  void _resumeStory() {
    if (!mounted) return;
    _progressCtrl.forward();
    final remaining =
        _storyDuration * (1.0 - _progressCtrl.value).clamp(0.0, 1.0).toDouble();
    _timer = Timer(remaining, _nextStory);
  }

  Future<void> _openReactionPicker() async {
    _pauseStory();
    final emoji = await showReactionPickerSheet(context);
    if (emoji != null) {
      await _trySendStoryReaction(emoji);
    }
    if (mounted) _resumeStory();
  }

  Future<void> _startStory() async {
    _timer?.cancel();
    _progressCtrl.reset();
    if (_stories.isEmpty) return;

    // Dispose previous video controller
    final oldCtrl = _videoCtrl;
    _videoCtrl = null;
    oldCtrl?.dispose();

    final story = _stories[_index];
    StoryService.instance.markViewed(widget.authorId, story.id);

    // Notify the author that we viewed their story (skip for own stories)
    final myId = CryptoService.instance.publicKeyHex;
    if (story.authorId != myId && myId.isNotEmpty) {
      unawaited(GossipRouter.instance.sendStoryView(
        storyId: story.id,
        authorId: story.authorId,
        viewerId: myId,
      ));
    }

    // Init video player (native file or web OPFS/blob/data URL).
    final vp = story.videoPath;
    if (vp != null && vp.isNotEmpty) {
      String? playable;
      if (kIsWeb) {
        if (_isInlineWebUri(vp)) {
          playable = vp;
        } else if (vp.startsWith('opfs://')) {
          playable = await webStoredFileObjectUrl(vp.split('#').first,
              mimeType: 'video/mp4');
        }
      } else if (File(vp).existsSync()) {
        playable = vp;
      }
      if (playable != null) {
        final ctrl = (kIsWeb && _isInlineWebUri(playable))
            ? VideoPlayerController.networkUrl(Uri.parse(playable))
            : VideoPlayerController.file(File(playable));
        try {
          await ctrl.initialize();
          ctrl.setLooping(true);
          ctrl.play();
          if (mounted) {
            setState(() => _videoCtrl = ctrl);
          } else {
            ctrl.dispose();
            return;
          }
        } catch (e) {
          debugPrint('[StoryViewer] Video init error: $e');
          ctrl.dispose();
        }
      }
    }

    _progressCtrl.forward();
    _timer = Timer(_storyDuration, _nextStory);
  }

  void _nextStory() {
    if (_index < _stories.length - 1) {
      setState(() => _index++);
      _startStory();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _prevStory() {
    if (_index > 0) {
      setState(() => _index--);
      _startStory();
    }
  }

  Future<void> _showViewersSheet(StoryItem story) async {
    _pauseStory();
    final viewers = List<String>.from(story.viewers);
    // Resolve viewer names from contacts DB
    final names = <String, String>{};
    for (final key in viewers) {
      final contact = await ChatStorageService.instance.getContact(key);
      names[key] = contact?.nickname ?? '${key.substring(0, 8)}…';
    }
    if (!mounted) {
      _resumeStory();
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Icon(Icons.visibility_outlined,
                      color: Colors.white70, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Просмотры: ${viewers.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (viewers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'Пока никто не смотрел',
                  style: TextStyle(color: Colors.white54, fontSize: 14),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: viewers.length,
                  itemBuilder: (_, i) {
                    final key = viewers[i];
                    final name = names[key] ?? key.substring(0, 8);
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 18,
                        backgroundColor: Colors.white12,
                        child: Text(
                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14),
                        ),
                      ),
                      title: Text(
                        name,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 14),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (mounted) _resumeStory();
  }

  Future<void> _deleteCurrentStory() async {
    _pauseStory();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить историю?'),
        content: const Text('История будет удалена и больше не будет видна.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppL10n.t('common_cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppL10n.t('common_delete'), style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      if (mounted) _resumeStory();
      return;
    }
    final story = _stories[_index];
    StoryService.instance.deleteStory(story.id, widget.authorId);
    // Broadcast deletion so other devices remove it too
    unawaited(GossipRouter.instance.sendStoryDelete(
      storyId: story.id,
      authorId: widget.authorId,
    ));
    // _onStoryUpdate will handle pop or index adjustment automatically
  }

  @override
  void dispose() {
    StoryService.instance.version.removeListener(_onStoryUpdate);
    _timer?.cancel();
    _progressCtrl.dispose();
    _videoCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_stories.isEmpty) return const SizedBox.shrink();
    // Prefer live story from service so incoming reactions update UI.
    final baseStory = _stories[_index];
    final story = StoryService.instance.findStory(baseStory.id) ?? baseStory;
    final bgColor = Color(story.bgColor);
    final myId = CryptoService.instance.publicKeyHex;
    final isAuthor = story.authorId == myId;

    final storyCanvas = GestureDetector(
      onTapDown: (details) {
        final box = context.findRenderObject() as RenderBox?;
        final width = box?.size.width ?? MediaQuery.of(context).size.width;
        if (details.localPosition.dx < width / 2) {
          _prevStory();
        } else {
          _nextStory();
        }
      },
      // Hold to pause, release to resume (Instagram/Telegram-style).
      onLongPressStart: (_) => _pauseStory(),
      onLongPressEnd: (_) {
        if (mounted) _resumeStory();
      },
      // Swipe down to dismiss.
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 250) {
          Navigator.of(context).maybePop();
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Story background — video, then image, then solid colour
          if (story.videoPath != null &&
              _videoCtrl != null &&
              _videoCtrl!.value.isInitialized)
            ClipRect(
              child: SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _videoCtrl!.value.size.width,
                    height: _videoCtrl!.value.size.height,
                    child: VideoPlayer(_videoCtrl!),
                  ),
                ),
              ),
            )
          else if (story.imagePath != null && story.imagePath!.isNotEmpty)
            _StoryImage(path: story.imagePath!, bgColor: bgColor)
          else
            Container(color: bgColor),

          // Dark gradient overlay at top for progress bars
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.25],
                colors: [Color(0x99000000), Colors.transparent],
              ),
            ),
          ),

          // Story text — positioned using textX/textY alignment from creator
          if (story.text.isNotEmpty)
            Align(
              alignment: Alignment(
                story.textX.clamp(-1.0, 1.0),
                story.textY.clamp(-1.0, 1.0),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 320),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: (story.imagePath != null ||
                          story.videoPath != null)
                      ? BoxDecoration(
                          color: Colors.black.withValues(
                            alpha: story.textBgOpacity > 0
                                ? story.textBgOpacity.clamp(0.0, 0.7).toDouble()
                                : 0.35,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        )
                      : null,
                  child: Text(
                    story.text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(story.textColor),
                      fontSize: story.textSize.clamp(14.0, 60.0),
                      fontWeight:
                          story.textBold ? FontWeight.w700 : FontWeight.w500,
                      fontStyle: story.textItalic
                          ? FontStyle.italic
                          : FontStyle.normal,
                      shadows: const [
                        Shadow(
                          blurRadius: 8,
                          color: Colors.black54,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          for (final ov in story.overlays)
            Align(
              alignment: Alignment(
                ov.x.clamp(-1.0, 1.0),
                ov.y.clamp(-1.0, 1.0),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  ov.value,
                  style: TextStyle(
                    fontSize: ov.size.clamp(20.0, 64.0),
                    shadows: const [
                      Shadow(blurRadius: 8, color: Colors.black54),
                    ],
                  ),
                ),
              ),
            ),

          // Freehand drawing layer
          if (story.strokes.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: StoryStrokesPainter(strokes: story.strokes),
                ),
              ),
            ),

          // Top: progress bars + header
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Progress bars
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    children: List.generate(_stories.length, (i) {
                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: i < _index
                              ? const _ProgressBar(progress: 1.0)
                              : i == _index
                                  ? AnimatedBuilder(
                                      animation: _progressCtrl,
                                      builder: (_, __) => _ProgressBar(
                                        progress: _progressCtrl.value,
                                      ),
                                    )
                                  : const _ProgressBar(progress: 0.0),
                        ),
                      );
                    }),
                  ),
                ),

                // Author header
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      AvatarWidget(
                        initials: widget.authorName.isNotEmpty
                            ? widget.authorName[0].toUpperCase()
                            : '?',
                        color: _authorColor,
                        emoji: _authorEmoji,
                        imagePath: _authorImage,
                        size: 34,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          widget.authorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            shadows: [
                              Shadow(blurRadius: 4, color: Colors.black54)
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _timeAgo(story.createdAt),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                      const Spacer(),
                      if (isAuthor)
                        GestureDetector(
                          onTap: _deleteCurrentStory,
                          child: Container(
                            margin: const EdgeInsets.only(right: 8),
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.delete_outline,
                                color: Colors.white, size: 20),
                          ),
                        ),
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: const Icon(Icons.close,
                            color: Colors.white, size: 24),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Bottom bar: reactions (author sees counter, viewer sees react button).
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: false,
              child: SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xAA000000), Colors.transparent],
                    ),
                  ),
                  child: Row(
                    children: [
                      if (isAuthor) ...[
                        // Author: view count (tappable → shows viewer list)
                        GestureDetector(
                          onTap: () => _showViewersSheet(story),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.visibility_outlined,
                                    color: Colors.white, size: 16),
                                const SizedBox(width: 6),
                                Text(
                                  '${story.viewers.length}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Author: aggregate reaction counter
                        if (story.totalReactions > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.favorite,
                                    color: Colors.white, size: 16),
                                const SizedBox(width: 6),
                                Text(
                                  '${story.totalReactions}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (story.totalReactions > 0) const SizedBox(width: 10),
                        if (story.reactions.isNotEmpty)
                          Flexible(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: ReactionsBar(
                                reactions: story.reactions,
                                myId: myId,
                                onTap: (_) {},
                                compact: true,
                              ),
                            ),
                          ),
                      ] else ...[
                        // Viewer: reply field (opens sheet) + react button
                        Expanded(
                          child: GestureDetector(
                            onTap: _sendingReply ? null : _openReplySheet,
                            child: Container(
                              height: 44,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              alignment: Alignment.centerLeft,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(color: Colors.white24),
                              ),
                              child: Text(
                                _sendingReply ? 'Отправка…' : 'Ответить…',
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 14),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () async {
                            _pauseStory();
                            await _trySendStoryReaction(
                                kQuickReactionEmojis.isNotEmpty
                                    ? kQuickReactionEmojis.first
                                    : '❤️');
                            if (mounted) _resumeStory();
                          },
                          onLongPress: _openReactionPicker,
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.14),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.favorite_border_rounded,
                                color: Colors.white, size: 22),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 900;
          if (!isWide) return storyCanvas;
          final maxFrameHeight =
              (constraints.maxHeight - 24).clamp(300.0, 1200.0).toDouble();
          final phoneWidthByHeight = maxFrameHeight * (9 / 19.5);
          final frameWidth = math.min(430.0, phoneWidthByHeight).toDouble();
          final frameHeight = frameWidth * (19.5 / 9);
          return Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: SizedBox(
                width: frameWidth,
                height: frameHeight,
                child: storyCanvas,
              ),
            ),
          );
        },
      ),
    );
  }

  static bool _isInlineWebUri(String v) =>
      v.startsWith('data:') ||
      v.startsWith('blob:') ||
      v.startsWith('http://') ||
      v.startsWith('https://');

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'только что';
    if (diff.inMinutes < 60) return '${diff.inMinutes} мин';
    return '${diff.inHours} ч';
  }
}

class _ProgressBar extends StatelessWidget {
  final double progress;
  const _ProgressBar({required this.progress});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: progress,
        backgroundColor: Colors.white38,
        valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
        minHeight: 3,
      ),
    );
  }
}

/// Renders a story image from a native file or a web path (OPFS / data URL).
class _StoryImage extends StatefulWidget {
  final String path;
  final Color bgColor;
  const _StoryImage({required this.path, required this.bgColor});

  @override
  State<_StoryImage> createState() => _StoryImageState();
}

class _StoryImageState extends State<_StoryImage> {
  Uint8List? _bytes;
  bool _useFile = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _StoryImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _bytes = null;
      _useFile = false;
      _load();
    }
  }

  Future<void> _load() async {
    final path = widget.path;
    if (!kIsWeb) {
      if (File(path).existsSync()) setState(() => _useFile = true);
      return;
    }
    Uint8List? bytes;
    try {
      if (isWebStoredFile(path)) {
        bytes = await readWebStoredFile(path);
      } else if (path.startsWith('data:')) {
        final comma = path.indexOf(',');
        if (comma > 0) {
          final meta = path.substring(0, comma);
          final data = path.substring(comma + 1);
          bytes = meta.contains(';base64')
              ? base64Decode(data)
              : Uint8List.fromList(utf8.encode(Uri.decodeFull(data)));
        }
      }
    } catch (_) {}
    if (mounted && bytes != null) setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    if (_useFile) {
      return Image.file(File(widget.path), fit: BoxFit.cover);
    }
    if (_bytes != null) {
      return Image.memory(_bytes!, fit: BoxFit.cover, gaplessPlayback: true);
    }
    return Container(color: widget.bgColor);
  }
}
