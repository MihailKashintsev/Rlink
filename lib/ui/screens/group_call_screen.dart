import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../models/contact.dart';
import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import '../../services/group_call_directory.dart';
import '../../services/group_call_service.dart';
import '../../services/group_service.dart';
import '../../services/screen_share_helper.dart';
import '../widgets/avatar_widget.dart';
import '../../l10n/app_l10n.dart';

const _kReactionEmojis = ['👍', '❤️', '😂', '😮', '👏', '🔥'];

Contact? _contactOf(String id) => ChatStorageService.instance
    .contactsNotifier.value
    .where((c) => c.publicKeyHex == id)
    .firstOrNull;

String _nameOf(String id) {
  if (id == CryptoService.instance.publicKeyHex) return AppL10n.t('Вы');
  return _contactOf(id)?.nickname ??
      '${id.substring(0, id.length.clamp(0, 8))}…';
}

/// Mesh group call: a stage (whoever is speaking / sharing their screen, or
/// whoever you pinned) over a strip of every participant, with mic / camera /
/// screen / reactions / hang-up. See [GroupCallService] for the protocol.
class GroupCallScreen extends StatefulWidget {
  final String title;

  const GroupCallScreen({super.key, required this.title});

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  final _svc = GroupCallService.instance;
  final Map<String, RTCVideoRenderer> _thumbRenderers = {};
  final Set<String> _thumbReady = {};
  final RTCVideoRenderer _stageRenderer = RTCVideoRenderer();
  bool _stageReady = false;
  String? _boundStageKey;
  String? _pinned;
  final List<_FloatingReaction> _floating = [];
  StreamSubscription<CallReaction>? _reactionSub;
  StreamSubscription<String>? _noticeSub;

  @override
  void initState() {
    super.initState();
    _svc.screenOpen.value = true;
    _svc.phase.addListener(_onPhase);
    for (final n in [
      _svc.remoteStreams,
      _svc.localStreamNotifier,
      _svc.screenStreamNotifier,
      _svc.participants,
      _svc.activeSpeaker,
      _svc.micEnabled,
      _svc.cameraEnabled,
      _svc.screenSharing,
      _svc.canAdminister,
    ]) {
      n.addListener(_sync);
    }
    _reactionSub = _svc.reactions.listen(_onReaction);
    _noticeSub = _svc.notices.listen((m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(m)));
    });
    unawaited(_stageRenderer.initialize().then((_) {
      _stageReady = true;
      _sync();
    }));
    _sync();
  }

  @override
  void dispose() {
    _svc.screenOpen.value = false;
    _svc.phase.removeListener(_onPhase);
    for (final n in [
      _svc.remoteStreams,
      _svc.localStreamNotifier,
      _svc.screenStreamNotifier,
      _svc.participants,
      _svc.activeSpeaker,
      _svc.micEnabled,
      _svc.cameraEnabled,
      _svc.screenSharing,
      _svc.canAdminister,
    ]) {
      n.removeListener(_sync);
    }
    _reactionSub?.cancel();
    _noticeSub?.cancel();
    for (final r in _thumbRenderers.values) {
      r.srcObject = null;
      unawaited(r.dispose());
    }
    _stageRenderer.srcObject = null;
    unawaited(_stageRenderer.dispose());
    super.dispose();
  }

  void _onPhase() {
    if (_svc.phase.value == GroupCallPhase.idle && mounted) {
      Navigator.of(context).maybePop();
    }
  }

  void _onReaction(CallReaction r) {
    if (!mounted) return;
    final item = _FloatingReaction(r.emoji, _nameOf(r.from), UniqueKey());
    setState(() => _floating.add(item));
    Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _floating.remove(item));
    });
  }

  String get _me => CryptoService.instance.publicKeyHex;

  /// Who is on stage: the pinned participant, else the newest screen sharer,
  /// else the active speaker, else the first other participant.
  String? _stageId() {
    final parts = _svc.participants.value;
    if (_pinned != null && parts.containsKey(_pinned)) return _pinned;
    String? sharer;
    var since = 0;
    parts.forEach((id, p) {
      if (p.screenSince > since) {
        since = p.screenSince;
        sharer = id;
      }
    });
    if (sharer != null) return sharer;
    final speaker = _svc.activeSpeaker.value;
    if (speaker != null && parts.containsKey(speaker)) return speaker;
    return parts.keys.where((k) => k != _me).firstOrNull ?? _me;
  }

  MediaStream? _streamFor(String id) {
    if (id == _me) {
      return _svc.screenStreamNotifier.value ?? _svc.localStreamNotifier.value;
    }
    return _svc.remoteStreams.value[id];
  }

  Future<void> _bindThumb(String id) async {
    var r = _thumbRenderers[id];
    if (r == null) {
      r = RTCVideoRenderer();
      _thumbRenderers[id] = r;
      await r.initialize();
      _thumbReady.add(id);
    }
    final s = _streamFor(id);
    if (r.srcObject != s) r.srcObject = s;
    if (mounted) setState(() {});
  }

  void _sync() {
    if (!mounted) return;
    final ids = _svc.participants.value.keys.toSet();
    for (final id in ids) {
      unawaited(_bindThumb(id));
    }
    for (final id in _thumbRenderers.keys.toList()) {
      if (!ids.contains(id)) {
        final r = _thumbRenderers.remove(id);
        _thumbReady.remove(id);
        r?.srcObject = null;
        unawaited(r?.dispose());
      }
    }
    if (_pinned != null && !ids.contains(_pinned)) _pinned = null;
    if (_stageReady) {
      final sid = _stageId();
      final stream = sid == null ? null : _streamFor(sid);
      // Rebind on stream identity change as well as on stage change.
      final key = '$sid|${stream?.id}';
      if (key != _boundStageKey || _stageRenderer.srcObject != stream) {
        _boundStageKey = key;
        _stageRenderer.srcObject = stream;
      }
    }
    setState(() {});
  }

  Widget _avatar(String id, double size) {
    final c = _contactOf(id);
    final name = _nameOf(id);
    return AvatarWidget(
      initials: name.isNotEmpty ? name[0].toUpperCase() : '?',
      color: c?.avatarColor ?? 0xFF5C6BC0,
      emoji: c?.avatarEmoji ?? '',
      imagePath: c?.avatarImagePath,
      size: size,
    );
  }

  Widget _micBadge(CallParticipant p, {double size = 18}) {
    final IconData icon;
    final Color bg;
    if (p.muted) {
      icon = Icons.mic_off;
      bg = Colors.red.shade600;
    } else if (p.speaking) {
      icon = Icons.mic;
      bg = Colors.green.shade600;
    } else {
      icon = Icons.mic_none;
      bg = Colors.black54;
    }
    return Container(
      padding: EdgeInsets.all(size * 0.22),
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Icon(icon, size: size, color: Colors.white),
    );
  }

  Widget _videoOrAvatar(String id, CallParticipant p, RTCVideoRenderer? r,
      {required bool stage, required double avatarSize}) {
    final showVideo = p.hasVideo && r != null && r.srcObject != null;
    if (!showVideo) {
      return Center(child: _avatar(id, avatarSize));
    }
    return RTCVideoView(
      r,
      mirror: id == _me && !p.screenSharing,
      objectFit: p.screenSharing
          ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
          : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    );
  }

  Widget _stage(String id) {
    final p = _svc.participants.value[id] ?? CallParticipant(id: id);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.grey.shade900,
            child: _videoOrAvatar(id, p, _stageRenderer,
                stage: true, avatarSize: 120),
          ),
          Positioned(
            left: 12,
            bottom: 12,
            child: Row(
              children: [
                _micBadge(p, size: 20),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    p.screenSharing ? AppL10n.f('{0} · экран', [_nameOf(id)]) : _nameOf(id),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          for (final f in _floating) _FloatingReactionView(key: f.key, item: f),
        ],
      ),
    );
  }

  Widget _thumb(String id) {
    final p = _svc.participants.value[id] ?? CallParticipant(id: id);
    final r = _thumbReady.contains(id) ? _thumbRenderers[id] : null;
    final selected = _stageId() == id;
    return GestureDetector(
      onTap: () => setState(() {
        _pinned = _pinned == id ? null : id;
        _sync();
      }),
      child: Container(
        width: 84,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: p.speaking
                ? Colors.green.shade500
                : (selected ? Colors.white70 : Colors.white12),
            width: p.speaking || selected ? 2.5 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: Colors.grey.shade900,
                child: _videoOrAvatar(id, p, r, stage: false, avatarSize: 40),
              ),
              Positioned(right: 4, top: 4, child: _micBadge(p, size: 12)),
              if (_pinned == id)
                const Positioned(
                    left: 4,
                    top: 4,
                    child: Icon(Icons.push_pin, size: 14, color: Colors.white)),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(_nameOf(id),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 10)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Audio-only layout: nobody has video, so cards instead of a stage.
  Widget _audioGrid() {
    final ids = _svc.participants.value.keys.toList();
    return Stack(
      children: [
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 20,
              runSpacing: 20,
              children: [
                for (final id in ids)
                  _AudioCard(
                    avatar: _avatar(id, 84),
                    name: _nameOf(id),
                    part: _svc.participants.value[id]!,
                    badge: _micBadge(_svc.participants.value[id]!, size: 18),
                  ),
              ],
            ),
          ),
        ),
        for (final f in _floating) _FloatingReactionView(key: f.key, item: f),
      ],
    );
  }

  Future<void> _showReactions() async {
    final emoji = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.grey.shade900,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 14,
            children: [
              for (final e in _kReactionEmojis)
                InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => Navigator.pop(ctx, e),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(e, style: const TextStyle(fontSize: 34)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (emoji != null) _svc.sendReaction(emoji);
  }

  Future<void> _showParticipants() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey.shade900,
      builder: (ctx) => _ParticipantsSheet(nameOf: _nameOf, avatar: _avatar),
    );
  }

  Future<void> _showInvite() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey.shade900,
      builder: (ctx) => const _InviteSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final parts = _svc.participants.value;
    final anyVideo = parts.values.any((p) => p.hasVideo);
    final stageMode = anyVideo;
    final room = _svc.room.value;
    final sid = _stageId();
    final ids = parts.keys.toList();
    final me = parts[_me];

    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 8, 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down,
                          color: Colors.white, size: 30),
                      tooltip: AppL10n.t('Свернуть'),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700)),
                          Text(
                              ids.length <= 1
                                  ? AppL10n.t('Ждём участников…')
                                  : AppL10n.f('Участников: {0}/{1}', [ids.length, kMaxCallParticipants]),
                              style: const TextStyle(
                                  color: Colors.white60, fontSize: 12)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.person_add_alt_1,
                          color: Colors.white),
                      tooltip: AppL10n.t('Пригласить'),
                      onPressed: _showInvite,
                    ),
                    IconButton(
                      icon: const Icon(Icons.people_alt_outlined,
                          color: Colors.white),
                      tooltip: AppL10n.t('Участники'),
                      onPressed: _showParticipants,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: stageMode && sid != null
                      ? _stage(sid)
                      : _audioGrid(),
                ),
              ),
              if (stageMode)
                SizedBox(
                  height: 96,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [for (final id in ids) _thumb(id)],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 14,
                  runSpacing: 10,
                  children: [
                    _RoundBtn(
                      icon: (me?.muted ?? false) ? Icons.mic_off : Icons.mic,
                      active: !(me?.muted ?? false),
                      onTap: () => _svc.toggleMic(me?.muted ?? false),
                    ),
                    _RoundBtn(
                      icon: (me?.cameraOn ?? false)
                          ? Icons.videocam
                          : Icons.videocam_off,
                      active: me?.cameraOn ?? false,
                      onTap: () => _svc.toggleCamera(!(me?.cameraOn ?? false)),
                    ),
                    if (ScreenShareHelper.supported)
                      _RoundBtn(
                        icon: _svc.screenSharing.value
                            ? Icons.stop_screen_share
                            : Icons.screen_share,
                        active: _svc.screenSharing.value,
                        onTap: () => _svc.screenSharing.value
                            ? _svc.stopScreenShare()
                            : _svc.startScreenShare(),
                      ),
                    _RoundBtn(
                      icon: Icons.emoji_emotions_outlined,
                      active: false,
                      onTap: _showReactions,
                    ),
                    _RoundBtn(
                      icon: Icons.call_end,
                      active: true,
                      color: Colors.red,
                      onTap: () => unawaited(_svc.leaveCall()),
                    ),
                  ],
                ),
              ),
              if (room == null) const SizedBox.shrink(),
            ],
          ),
        ),
      ),
    );
  }
}

class _AudioCard extends StatelessWidget {
  final Widget avatar;
  final String name;
  final CallParticipant part;
  final Widget badge;

  const _AudioCard({
    required this.avatar,
    required this.name,
    required this.part,
    required this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 110,
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: part.speaking
                        ? Colors.green.shade500
                        : Colors.transparent,
                    width: 3,
                  ),
                ),
                child: avatar,
              ),
              Positioned(right: 0, bottom: 0, child: badge),
            ],
          ),
          const SizedBox(height: 8),
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ],
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color? color;
  final VoidCallback? onTap;

  const _RoundBtn(
      {required this.icon, required this.active, this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color ?? (active ? Colors.white : Colors.white24),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Icon(icon,
              color: color != null || !active ? Colors.white : Colors.black,
              size: 24),
        ),
      ),
    );
  }
}

class _FloatingReaction {
  final String emoji;
  final String who;
  final Key key;
  _FloatingReaction(this.emoji, this.who, this.key);
}

class _FloatingReactionView extends StatelessWidget {
  final _FloatingReaction item;
  const _FloatingReactionView({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final dx = (item.key.hashCode % 5) * 14.0;
    return Positioned(
      right: 16 + dx,
      bottom: 0,
      top: 0,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 2500),
          curve: Curves.easeOut,
          builder: (_, t, __) => Align(
            alignment: Alignment(0, 0.9 - 1.6 * t),
            child: Opacity(
              opacity: (1 - t).clamp(0.0, 1.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(item.emoji, style: const TextStyle(fontSize: 38)),
                  Text(item.who,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 10)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ParticipantsSheet extends StatelessWidget {
  final String Function(String) nameOf;
  final Widget Function(String, double) avatar;

  const _ParticipantsSheet({required this.nameOf, required this.avatar});

  @override
  Widget build(BuildContext context) {
    final svc = GroupCallService.instance;
    return SafeArea(
      child: ValueListenableBuilder<Map<String, CallParticipant>>(
        valueListenable: svc.participants,
        builder: (ctx, parts, _) {
          final me = CryptoService.instance.publicKeyHex;
          final creator = svc.room.value?.creatorId;
          return ValueListenableBuilder<bool>(
            valueListenable: svc.canAdminister,
            builder: (ctx, admin, _) => ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(AppL10n.t('Участники'),
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                ),
                for (final p in parts.values)
                  ListTile(
                    leading: avatar(p.id, 40),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(nameOf(p.id),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white)),
                        ),
                        if (p.id == creator)
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Icon(Icons.star,
                                size: 15, color: Colors.amber),
                          ),
                      ],
                    ),
                    subtitle: Text(
                      [
                        if (p.muted) AppL10n.t('микрофон выкл'),
                        if (p.cameraOn) AppL10n.t('камера'),
                        if (p.screenSharing) AppL10n.t('экран'),
                        if (!p.connected && p.id != me) AppL10n.t('подключается…'),
                      ].join(' · '),
                      style: const TextStyle(color: Colors.white54),
                    ),
                    trailing: admin && p.id != me
                        ? PopupMenuButton<String>(
                            iconColor: Colors.white70,
                            onSelected: (v) {
                              if (v == 'mute') svc.forceMute(p.id);
                              if (v == 'video') svc.forceVideoOff(p.id);
                              if (v == 'kick') svc.kick(p.id);
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                  value: 'mute',
                                  child: Text(AppL10n.t('Выключить микрофон'))),
                              PopupMenuItem(
                                  value: 'video',
                                  child: Text(AppL10n.t('Выключить видео'))),
                              PopupMenuItem(
                                  value: 'kick', child: Text(AppL10n.t('Исключить'))),
                            ],
                          )
                        : null,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _InviteSheet extends StatefulWidget {
  const _InviteSheet();

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  final Set<String> _sent = {};
  List<String>? _candidates;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final svc = GroupCallService.instance;
    final r = svc.room.value;
    final inCall = svc.participants.value.keys.toSet();
    final me = CryptoService.instance.publicKeyHex;
    List<String> ids;
    if (r?.groupId != null) {
      ids = (await GroupService.instance.getGroup(r!.groupId!))?.memberIds ??
          const [];
    } else {
      ids = ChatStorageService.instance.contactsNotifier.value
          .map((c) => c.publicKeyHex)
          .toList();
    }
    if (!mounted) return;
    setState(() => _candidates =
        ids.where((i) => i != me && !inCall.contains(i)).toList());
  }

  @override
  Widget build(BuildContext context) {
    final c = _candidates;
    return SafeArea(
      child: c == null
          ? const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()))
          : ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(AppL10n.t('Пригласить в звонок'),
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                ),
                if (c.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(AppL10n.t('Некого приглашать'),
                        style: TextStyle(color: Colors.white54)),
                  ),
                for (final id in c)
                  ListTile(
                    title: Text(_nameOf(id),
                        style: const TextStyle(color: Colors.white)),
                    trailing: _sent.contains(id)
                        ? const Icon(Icons.check, color: Colors.green)
                        : const Icon(Icons.call, color: Colors.white70),
                    onTap: _sent.contains(id)
                        ? null
                        : () {
                            setState(() => _sent.add(id));
                            unawaited(GroupCallService.instance
                                .inviteMember(id));
                          },
                  ),
              ],
            ),
    );
  }
}

// ── entry helpers (used from chats and main.dart) ───────────────────────────

void openGroupCallScreen(BuildContext context, String title) {
  if (GroupCallService.instance.screenOpen.value) return;
  unawaited(Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => GroupCallScreen(title: title))));
}

String _titleFor(GroupCallRoomInfo? r, String? groupName) {
  if (groupName != null) return groupName;
  return r?.isGroupRoom == true ? AppL10n.t('Групповой звонок') : AppL10n.t('Звонок');
}

Future<void> _showStartError(BuildContext context, Object e) async {
  if (!context.mounted) return;
  final msg = e is StateError && e.message == 'busy'
      ? AppL10n.t('Вы уже в звонке')
      : e is StateError && e.message == 'full'
          ? AppL10n.f('Комната заполнена (до {0} человек)', [kMaxCallParticipants])
          : AppL10n.t('Не удалось начать звонок');
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// Starts (or joins) the call for a group topic and opens the call screen.
Future<void> startOrJoinGroupCall(
  BuildContext context, {
  required String groupId,
  required String groupName,
  String? topicId,
  required bool video,
}) async {
  try {
    await GroupCallService.instance.startOrJoinGroupRoom(
        groupId: groupId, topicId: topicId, video: video);
  } catch (e) {
    if (context.mounted) await _showStartError(context, e);
    return;
  }
  if (context.mounted) openGroupCallScreen(context, groupName);
}

/// Starts an invite-only call from a regular chat.
Future<void> startAdHocCall(
  BuildContext context, {
  required String peerId,
  required String title,
  required bool video,
}) async {
  try {
    await GroupCallService.instance.startAdHocRoom(peerId: peerId, video: video);
  } catch (e) {
    if (context.mounted) await _showStartError(context, e);
    return;
  }
  if (context.mounted) openGroupCallScreen(context, title);
}

/// Invite prompt shown app-wide when someone rings us into a room.
Future<void> showGroupCallInviteDialog(
    BuildContext context, GroupCallInvite invite) async {
  String title = AppL10n.t('Звонок');
  if (invite.room.groupId != null) {
    final g = await GroupService.instance.getGroup(invite.room.groupId!);
    title = g?.name ?? AppL10n.t('Групповой звонок');
  }
  if (!context.mounted) return;
  final accept = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(
          AppL10n.f('{0} зовёт вас в {1}звонок', [_nameOf(invite.fromId), invite.room.video ? AppL10n.t('видео') : AppL10n.t('аудио')])),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppL10n.t('Отклонить'))),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppL10n.t('Присоединиться'))),
      ],
    ),
  );
  if (accept == true) {
    await GroupCallService.instance.acceptInvite();
    if (GroupCallService.instance.isActive && context.mounted) {
      openGroupCallScreen(context, _titleFor(invite.room, title));
    }
  } else {
    await GroupCallService.instance.declineInvite();
  }
}
