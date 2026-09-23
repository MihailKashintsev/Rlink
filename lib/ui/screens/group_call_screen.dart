import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../services/chat_storage_service.dart';
import '../../services/crypto_service.dart';
import '../../services/group_call_service.dart';

/// Mesh group call: a grid of tiles (you + every connected participant) with
/// mic / camera / leave controls. See [GroupCallService] for the protocol.
class GroupCallScreen extends StatefulWidget {
  final String groupName;

  const GroupCallScreen({super.key, required this.groupName});

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  final _svc = GroupCallService.instance;
  final Map<String, RTCVideoRenderer> _renderers = {};
  final Set<String> _ready = {};
  static const _localKey = '__local__';

  @override
  void initState() {
    super.initState();
    _svc.phase.addListener(_onPhase);
    _svc.remoteStreams.addListener(_syncRenderers);
    _svc.localStreamNotifier.addListener(_syncRenderers);
    _svc.participantIds.addListener(_rebuild);
    _svc.micEnabled.addListener(_rebuild);
    _svc.cameraEnabled.addListener(_rebuild);
    _syncRenderers();
  }

  @override
  void dispose() {
    _svc.phase.removeListener(_onPhase);
    _svc.remoteStreams.removeListener(_syncRenderers);
    _svc.localStreamNotifier.removeListener(_syncRenderers);
    _svc.participantIds.removeListener(_rebuild);
    _svc.micEnabled.removeListener(_rebuild);
    _svc.cameraEnabled.removeListener(_rebuild);
    for (final r in _renderers.values) {
      r.srcObject = null;
      unawaited(r.dispose());
    }
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onPhase() {
    if (_svc.phase.value == GroupCallPhase.idle && mounted) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _bind(String key, MediaStream? stream) async {
    var r = _renderers[key];
    if (r == null) {
      r = RTCVideoRenderer();
      _renderers[key] = r;
      await r.initialize();
      _ready.add(key);
    }
    if (r.srcObject != stream) r.srcObject = stream;
    _rebuild();
  }

  void _syncRenderers() {
    unawaited(_bind(_localKey, _svc.localStreamNotifier.value));
    final remote = _svc.remoteStreams.value;
    for (final e in remote.entries) {
      unawaited(_bind(e.key, e.value));
    }
    final stale = _renderers.keys
        .where((k) => k != _localKey && !remote.containsKey(k))
        .toList();
    for (final k in stale) {
      final r = _renderers.remove(k);
      _ready.remove(k);
      r?.srcObject = null;
      unawaited(r?.dispose());
    }
  }

  String _nick(String id) {
    final c = ChatStorageService.instance.contactsNotifier.value
        .where((c) => c.publicKeyHex == id)
        .firstOrNull;
    return c?.nickname ?? '${id.substring(0, id.length.clamp(0, 8))}…';
  }

  Widget _tile(String key, String label, {required bool mirror}) {
    final r = _renderers[key];
    final ready = _ready.contains(key) && r != null && r.srcObject != null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.grey.shade900,
            child: ready
                ? RTCVideoView(
                    r,
                    mirror: mirror,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  )
                : const Center(
                    child: Icon(Icons.person, color: Colors.white38, size: 48)),
          ),
          Positioned(
            left: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final remoteIds = _svc.remoteStreams.value.keys.toList();
    final tiles = <Widget>[
      _tile(_localKey, 'Вы', mirror: true),
      for (final id in remoteIds) _tile(id, _nick(id), mirror: false),
    ];
    // 1 column for 1-2 tiles, 2 columns beyond — keeps 4-5 tiles readable.
    final cols = tiles.length <= 2 ? 1 : 2;
    final waiting = _svc.participantIds.value.length <= 1;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.groupName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w700)),
                        Text(
                            waiting
                                ? 'Ждём участников…'
                                : 'Участников: ${_svc.participantIds.value.length}',
                            style: const TextStyle(
                                color: Colors.white60, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: GridView.count(
                  crossAxisCount: cols,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: cols == 1 ? 1.4 : 0.85,
                  children: tiles,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _RoundBtn(
                    icon: _svc.micEnabled.value ? Icons.mic : Icons.mic_off,
                    active: _svc.micEnabled.value,
                    onTap: () => _svc.toggleMic(!_svc.micEnabled.value),
                  ),
                  const SizedBox(width: 18),
                  _RoundBtn(
                    icon: _svc.cameraEnabled.value
                        ? Icons.videocam
                        : Icons.videocam_off,
                    active: _svc.cameraEnabled.value,
                    onTap: _svc.isVideoEnabled
                        ? () => _svc.toggleCamera(!_svc.cameraEnabled.value)
                        : null,
                  ),
                  const SizedBox(width: 18),
                  _RoundBtn(
                    icon: Icons.call_end,
                    active: true,
                    color: Colors.red,
                    onTap: () => unawaited(_svc.leaveCall()),
                  ),
                ],
              ),
            ),
          ],
        ),
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
      color: color ?? (active ? Colors.white24 : Colors.white70),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Icon(icon,
              color: color != null || active ? Colors.white : Colors.black,
              size: 26),
        ),
      ),
    );
  }
}

/// Bottom-sheet-free invite prompt: shown app-wide when a group call invite
/// arrives (see main.dart's listener).
Future<void> showGroupCallInviteDialog(
    BuildContext context, GroupCallInvite invite, String groupName) async {
  final inviter = ChatStorageService.instance.contactsNotifier.value
          .where((c) => c.publicKeyHex == invite.fromId)
          .firstOrNull
          ?.nickname ??
      'Участник';
  final accept = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text('Групповой звонок · $groupName'),
      content: Text('$inviter зовёт вас в ${invite.video ? "видео" : "аудио"}звонок'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отклонить')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Присоединиться')),
      ],
    ),
  );
  if (accept == true) {
    await GroupCallService.instance.acceptInvite();
    if (GroupCallService.instance.isActive && context.mounted) {
      unawaited(Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => GroupCallScreen(groupName: groupName))));
    }
  } else {
    await GroupCallService.instance.declineInvite();
  }
}

/// Starts a group call to [memberIds] and opens the call screen.
Future<void> startGroupCallAndOpen(
  BuildContext context, {
  required String groupId,
  required String groupName,
  required List<String> memberIds,
  required bool video,
}) async {
  try {
    await GroupCallService.instance.startGroupCall(
      groupId: groupId,
      memberIds: memberIds
          .where((m) => m != CryptoService.instance.publicKeyHex)
          .toList(),
      video: video,
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e is StateError && e.message == 'busy'
              ? 'Вы уже в звонке'
              : 'Не удалось начать звонок')));
    }
    return;
  }
  if (context.mounted) {
    unawaited(Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => GroupCallScreen(groupName: groupName))));
  }
}
