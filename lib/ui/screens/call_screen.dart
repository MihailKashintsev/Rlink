import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../services/call_service.dart';
import '../../services/call_proximity_service.dart';
import '../../services/sound_effects_service.dart' show CallFxSound;
import '../widgets/avatar_widget.dart';
import '../widgets/wave_line.dart';

class CallScreen extends StatefulWidget {
  final CallSessionInfo session;
  final String peerName;
  final int peerAvatarColor;
  final String peerAvatarEmoji;
  final String? peerAvatarImagePath;

  const CallScreen({
    super.key,
    required this.session,
    required this.peerName,
    this.peerAvatarColor = 0xFF5C6BC0,
    this.peerAvatarEmoji = '',
    this.peerAvatarImagePath,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen>
    with SingleTickerProviderStateMixin {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  /// Ambient loop for the gradient drift + avatar ring pulse.
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  bool _micOn = true;
  bool _camOn = true;
  VoidCallback? _phaseListener;
  bool _initialRouteApplied = false;
  VoidCallback? _streamListener;
  VoidCallback? _remoteGenListener;
  VoidCallback? _speakerListener;

  /// В видеозвонке: true — большой кадр собеседника, false — большой свой.
  bool _mainShowsPeer = true;

  // Falling-emoji overlay for in-call reaction sounds (see _openFxSheet).
  // _rainKey changes on every trigger so a repeat of the same emoji restarts
  // the animation instead of being a no-op.
  CallFxSound? _rainFx;
  int _rainKey = 0;
  VoidCallback? _fxListener;

  @override
  void initState() {
    super.initState();
    _fxListener = _onFxSignal;
    CallService.instance.fxSignal.addListener(_fxListener!);
    _init();
  }

  void _onFxSignal() {
    final fx = CallService.instance.lastFx;
    if (fx == null || !mounted) return;
    setState(() {
      _rainFx = fx;
      _rainKey++;
    });
  }

  String _initials(String name) {
    final t = name.trim();
    if (t.isEmpty) return '?';
    return t.substring(0, 1).toUpperCase();
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    if (!mounted) return;
    await _remoteRenderer.initialize();
    if (!mounted) return;

    try {
      if (widget.session.incoming) {
        await CallService.instance.acceptIncoming(widget.session);
        if (!mounted) return;
      }
      final local = await CallService.instance.getLocalStream();
      if (!mounted) return;
      _localRenderer.srcObject = local;
    } catch (e) {
      debugPrint('[CallScreen] _init error: $e');
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
            content: Text('Не удалось получить доступ к микрофону/камере')),
      );
      Navigator.maybeOf(context)?.maybePop();
      return;
    }

    _bindRemoteRenderer();

    _streamListener = _bindRemoteRenderer;
    CallService.instance.remoteStreamNotifier.addListener(_streamListener!);

    _remoteGenListener = _bindRemoteRenderer;
    CallService.instance.remoteStreamGeneration
        .addListener(_remoteGenListener!);

    _phaseListener = () {
      if (!mounted) return;
      final phase = CallService.instance.phase.value;
      // On connect, route audio calls to the EARPIECE by default (not the
      // loudspeaker) — video calls go to the speaker. Applied once so the user's
      // manual speaker toggle afterwards is respected.
      if (phase == CallPhase.connected && !_initialRouteApplied) {
        _initialRouteApplied = true;
        unawaited(
            CallService.instance.setSpeakerphone(widget.session.videoEnabled));
      }
      unawaited(_syncProximityMonitoring());
      if (phase == CallPhase.failed || phase == CallPhase.ended) {
        if (phase == CallPhase.failed) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('Соединение не удалось')),
          );
        }
        Navigator.maybeOf(context)?.maybePop();
      }
    };
    CallService.instance.phase.addListener(_phaseListener!);
    _speakerListener = () {
      if (!mounted) return;
      unawaited(_syncProximityMonitoring());
      setState(() {});
    };
    CallService.instance.speakerOn.addListener(_speakerListener!);
    if (CallService.instance.phase.value == CallPhase.connected &&
        !_initialRouteApplied) {
      _initialRouteApplied = true;
      unawaited(
          CallService.instance.setSpeakerphone(widget.session.videoEnabled));
    }
    unawaited(_syncProximityMonitoring());
    if (mounted) setState(() {});
  }

  void _bindRemoteRenderer() {
    final stream = CallService.instance.remoteStream;
    if (_remoteRenderer.srcObject != stream) {
      _remoteRenderer.srcObject = stream;
    } else if (stream != null) {
      // Новый трек в том же MediaStream — перепривязываем рендерер.
      _remoteRenderer.srcObject = null;
      _remoteRenderer.srcObject = stream;
    }
    if (mounted) setState(() {});
  }

  Future<void> _syncProximityMonitoring() async {
    final audioOnly = !widget.session.videoEnabled;
    final speaker = CallService.instance.speakerOn.value;
    final phase = CallService.instance.phase.value;
    final enabled = audioOnly && !speaker && phase == CallPhase.connected;
    await CallProximityService.instance.setEnabled(enabled);
  }

  String _formatElapsed(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Widget _callTopOverlay() {
    return Positioned(
      left: 12,
      right: 12,
      top: 8,
      child: Row(
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: CallService.instance.peerIsRecording,
            builder: (_, rec, __) {
              if (!rec) return const SizedBox.shrink();
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.fiber_manual_record,
                        color: Colors.white, size: 14),
                    SizedBox(width: 6),
                    Text(
                      'Идёт запись',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const Spacer(),
          ValueListenableBuilder<bool>(
            valueListenable: CallService.instance.localRecording,
            builder: (_, rec, __) {
              if (!rec) return const SizedBox.shrink();
              return ValueListenableBuilder<Duration>(
                valueListenable: CallService.instance.recordingElapsed,
                builder: (_, recElapsed, __) {
                  return Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.fiber_manual_record,
                            color: Colors.white, size: 12),
                        const SizedBox(width: 6),
                        Text(
                          _formatElapsed(recElapsed),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
          ValueListenableBuilder<Duration>(
            valueListenable: CallService.instance.callElapsed,
            builder: (_, elapsed, __) {
              if (elapsed == Duration.zero) return const SizedBox.shrink();
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _formatElapsed(elapsed),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    if (_phaseListener != null) {
      CallService.instance.phase.removeListener(_phaseListener!);
      _phaseListener = null;
    }
    if (_streamListener != null) {
      CallService.instance.remoteStreamNotifier
          .removeListener(_streamListener!);
      _streamListener = null;
    }
    if (_remoteGenListener != null) {
      CallService.instance.remoteStreamGeneration
          .removeListener(_remoteGenListener!);
      _remoteGenListener = null;
    }
    if (_speakerListener != null) {
      CallService.instance.speakerOn.removeListener(_speakerListener!);
      _speakerListener = null;
    }
    if (_fxListener != null) {
      CallService.instance.fxSignal.removeListener(_fxListener!);
      _fxListener = null;
    }
    unawaited(CallProximityService.instance.stop());
    _ambient.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  Future<void> _end() async {
    await CallService.instance.endCall();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.session.videoEnabled) {
      return _buildAudioCallUi(context);
    }
    return _buildVideoCallUi(context);
  }

  Widget _buildAudioCallUi(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: ValueListenableBuilder<bool>(
        valueListenable: CallProximityService.instance.isNear,
        builder: (_, near, __) {
          return Stack(
            children: [
              Positioned(
                width: 1,
                height: 1,
                left: -10,
                top: -10,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.01,
                    child: RTCVideoView(_remoteRenderer),
                  ),
                ),
              ),
              Positioned.fill(child: _ambientBackground()),
              SafeArea(
                child: Column(
                  children: [
                    const SizedBox(height: 52),
                    _pulsingAvatar(),
                    const SizedBox(height: 24),
                    Text(
                      widget.peerName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _statusLine(),
                    const SizedBox(height: 36),
                    ValueListenableBuilder<CallPhase>(
                      valueListenable: CallService.instance.phase,
                      builder: (_, phase, __) {
                        final live = phase == CallPhase.connected;
                        return AnimatedOpacity(
                          opacity: live ? 1 : 0.45,
                          duration: const Duration(milliseconds: 300),
                          child: SizedBox(
                            width: 250,
                            height: 56,
                            child: WaveLine(
                              seed: widget.peerName.hashCode,
                              progress: 1.0,
                              animating: live,
                              level:
                                  live ? CallService.instance.audioLevel : null,
                              activeColor: Colors.white.withValues(alpha: 0.95),
                              inactiveColor: Colors.white24,
                              strokeWidth: 2.8,
                            ),
                          ),
                        );
                      },
                    ),
                    const Spacer(),
                    _audioControls(),
                    const SizedBox(height: 44),
                  ],
                ),
              ),
              _callTopOverlay(),
              if (near)
                Positioned.fill(
                  child: AbsorbPointer(
                    absorbing: true,
                    child: Container(color: Colors.black),
                  ),
                ),
              if (_rainFx != null)
                Positioned.fill(
                  child: _EmojiRainOverlay(
                    key: ValueKey(_rainKey),
                    emoji: _rainFx!.emoji,
                    onDone: () {
                      if (mounted) setState(() => _rainFx = null);
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Soft colour glow drawn from the peer's avatar colour, gently drifting,
  /// fading to black at the edges.
  Widget _ambientBackground() {
    final base = Color(widget.peerAvatarColor);
    return AnimatedBuilder(
      animation: _ambient,
      builder: (_, __) {
        final a = math.sin(_ambient.value * 2 * math.pi);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(a * 0.10, -0.55 + a * 0.05),
              radius: 1.25,
              colors: [
                Color.lerp(base, Colors.black, 0.40)!,
                Color.lerp(base, Colors.black, 0.74)!,
                Colors.black,
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
        );
      },
    );
  }

  Widget _pulsingAvatar() {
    return ValueListenableBuilder<CallPhase>(
      valueListenable: CallService.instance.phase,
      builder: (_, phase, __) {
        final ringing =
            phase == CallPhase.ringing || phase == CallPhase.connecting;
        return SizedBox(
          width: 196,
          height: 196,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (ringing)
                AnimatedBuilder(
                  animation: _ambient,
                  builder: (_, __) {
                    final p = _ambient.value;
                    final p2 = (p + 0.5) % 1.0;
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        _ring(124 + p * 64, (1 - p) * 0.34),
                        _ring(124 + p2 * 64, (1 - p2) * 0.28),
                      ],
                    );
                  },
                ),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.82, end: 1.0),
                duration: const Duration(milliseconds: 460),
                curve: const Cubic(0.23, 1, 0.32, 1),
                builder: (_, s, child) =>
                    Transform.scale(scale: s, child: child),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Color(widget.peerAvatarColor)
                            .withValues(alpha: 0.45),
                        blurRadius: 34,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: AvatarWidget(
                    initials: _initials(widget.peerName),
                    color: widget.peerAvatarColor,
                    emoji: widget.peerAvatarEmoji,
                    imagePath: widget.peerAvatarImagePath,
                    size: 124,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _ring(double size, double opacity) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: opacity.clamp(0.0, 1.0)),
          width: 1.6,
        ),
      ),
    );
  }

  Widget _statusLine() {
    return ValueListenableBuilder<CallPhase>(
      valueListenable: CallService.instance.phase,
      builder: (_, phase, __) {
        if (phase == CallPhase.connected) {
          return ValueListenableBuilder<Duration>(
            valueListenable: CallService.instance.callElapsed,
            builder: (_, elapsed, __) => Text(
              elapsed == Duration.zero
                  ? 'Аудиозвонок'
                  : _formatElapsed(elapsed),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 15,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          );
        }
        final label = switch (phase) {
          CallPhase.ringing when widget.session.incoming => 'Входящий звонок',
          CallPhase.ringing => 'Ждём ответа…',
          CallPhase.connecting => 'Соединение…',
          CallPhase.failed => 'Соединение не удалось',
          CallPhase.ended => 'Звонок завершён',
          CallPhase.idle => 'Звонок',
          CallPhase.connected => 'Аудиозвонок',
        };
        return Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 15),
        );
      },
    );
  }

  /// Meet-style reaction sheet: tap an emoji, both sides hear the sound.
  void _openFxSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Text('Звуковой эффект',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final fx in CallFxSound.values)
                    _FxButton(
                      fx: fx,
                      onTap: () {
                        Navigator.pop(ctx);
                        unawaited(CallService.instance.sendCallFx(fx));
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _audioControls() {
    // Horizontally scrollable: with the FX button this row can run past a
    // narrow phone's width, and scrolling is a much smaller regression than
    // an overflow clip would be.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CallButton(
            icon: _micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
            label: _micOn ? 'Микрофон' : 'Без звука',
            active: !_micOn,
            onTap: () async {
              _micOn = !_micOn;
              await CallService.instance.toggleMic(_micOn);
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(width: 18),
          _CallButton(
            icon: Icons.theater_comedy_rounded,
            label: 'Эффект',
            onTap: _openFxSheet,
          ),
          const SizedBox(width: 18),
          ValueListenableBuilder<bool>(
            valueListenable: CallService.instance.speakerOn,
            builder: (_, speaker, __) {
              return _CallButton(
                icon: speaker
                    ? Icons.volume_up_rounded
                    : Icons.volume_down_rounded,
                label: 'Динамик',
                active: speaker,
                onTap: () async {
                  await CallService.instance.setSpeakerphone(!speaker);
                  await _syncProximityMonitoring();
                },
              );
            },
          ),
          const SizedBox(width: 18),
          ValueListenableBuilder<bool>(
            valueListenable: CallService.instance.localRecording,
            builder: (_, rec, __) {
              return _CallButton(
                icon: rec
                    ? Icons.stop_rounded
                    : Icons.fiber_manual_record_rounded,
                label: rec ? 'Стоп' : 'Запись',
                active: rec,
                activeColor: Colors.red,
                onTap: () async {
                  await CallService.instance.setCallRecording(!rec);
                  if (mounted) setState(() {});
                },
              );
            },
          ),
          const SizedBox(width: 18),
          _CallButton(
            icon: Icons.call_end_rounded,
            label: 'Завершить',
            onTap: _end,
            background: Colors.red,
            foreground: Colors.white,
          ),
        ],
      ),
    );
  }

  Widget _buildVideoCallUi(BuildContext context) {
    final hasRemote = _remoteRenderer.srcObject != null;
    final mainRemote = _mainShowsPeer;

    Widget surface(RTCVideoRenderer r, {required bool mirror}) {
      final isLocal = identical(r, _localRenderer);
      if (!(isLocal || hasRemote)) {
        return Center(
          child: Text(
            'Соединение с ${widget.peerName}...',
            style: const TextStyle(color: Colors.white70),
          ),
        );
      }
      return RTCVideoView(
        r,
        mirror: mirror,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      );
    }

    final mainRenderer = mainRemote ? _remoteRenderer : _localRenderer;
    final thumbRenderer = mainRemote ? _localRenderer : _remoteRenderer;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(
                color: Colors.black,
                child: surface(mainRenderer, mirror: !mainRemote),
              ),
            ),
            // Self/other preview — tap to swap which feed is fullscreen.
            Positioned(
              right: 12,
              top: 12,
              width: 116,
              height: 168,
              child: GestureDetector(
                onTap: () => setState(() => _mainShowsPeer = !_mainShowsPeer),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white38, width: 1.5),
                    boxShadow: const [
                      BoxShadow(color: Colors.black54, blurRadius: 8),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      surface(thumbRenderer, mirror: mainRemote),
                      Positioned(
                        right: 5,
                        bottom: 5,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.black45,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.swap_horiz_rounded,
                              size: 15, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _callTopOverlay(),
            Positioned(
              left: 0,
              right: 0,
              bottom: 22,
              child: Center(
                child: SingleChildScrollView(
                  // Six controls in a fixed-width pill risks overflow on a
                  // narrow phone — scrolling degrades gracefully, an overflow
                  // clip doesn't.
                  scrollDirection: Axis.horizontal,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.42),
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _videoCtl(
                          _micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
                          active: !_micOn,
                          onTap: () async {
                            _micOn = !_micOn;
                            await CallService.instance.toggleMic(_micOn);
                            if (mounted) setState(() {});
                          },
                        ),
                        const SizedBox(width: 12),
                        _videoCtl(
                          Icons.theater_comedy_rounded,
                          onTap: _openFxSheet,
                        ),
                        const SizedBox(width: 12),
                        _videoCtl(
                          _camOn
                              ? Icons.videocam_rounded
                              : Icons.videocam_off_rounded,
                          active: !_camOn,
                          onTap: () async {
                            _camOn = !_camOn;
                            await CallService.instance.toggleCamera(_camOn);
                            if (mounted) setState(() {});
                          },
                        ),
                        const SizedBox(width: 12),
                        _videoCtl(
                          Icons.flip_camera_ios_rounded,
                          onTap: _camOn
                              ? () => CallService.instance.switchCamera()
                              : null,
                        ),
                        const SizedBox(width: 12),
                        ValueListenableBuilder<bool>(
                          valueListenable: CallService.instance.localRecording,
                          builder: (_, rec, __) => _videoCtl(
                            rec
                                ? Icons.stop_rounded
                                : Icons.fiber_manual_record_rounded,
                            active: rec,
                            activeColor: Colors.red,
                            onTap: () async {
                              await CallService.instance.setCallRecording(!rec);
                              if (mounted) setState(() {});
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        _videoCtl(
                          Icons.call_end_rounded,
                          background: Colors.red,
                          foreground: Colors.white,
                          onTap: _end,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_rainFx != null)
              Positioned.fill(
                child: _EmojiRainOverlay(
                  key: ValueKey(_rainKey),
                  emoji: _rainFx!.emoji,
                  onDone: () {
                    if (mounted) setState(() => _rainFx = null);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Compact circular call control for the video-call bar (icon only, with a
  /// pressed-in feel and an active/toggled-off state).
  Widget _videoCtl(
    IconData icon, {
    required VoidCallback? onTap,
    bool active = false,
    Color? activeColor,
    Color? background,
    Color? foreground,
  }) {
    final bg = background ??
        (active
            ? (activeColor ?? Colors.white).withValues(alpha: 0.95)
            : Colors.white.withValues(alpha: 0.16));
    final fg = foreground ??
        (active
            ? (activeColor != null ? Colors.white : Colors.black)
            : Colors.white);
    return Material(
      color: bg,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 52,
          height: 52,
          child: Icon(
            icon,
            size: 24,
            color: onTap == null ? fg.withValues(alpha: 0.4) : fg,
          ),
        ),
      ),
    );
  }
}

/// A round call-control button with a label and scale-on-press feedback.
class _CallButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color? activeColor;
  final Color? background;
  final Color? foreground;

  const _CallButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.activeColor,
    this.background,
    this.foreground,
  });

  @override
  State<_CallButton> createState() => _CallButtonState();
}

class _CallButtonState extends State<_CallButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.background ??
        (widget.active
            ? (widget.activeColor ?? Colors.white).withValues(alpha: 0.95)
            : Colors.white.withValues(alpha: 0.14));
    final fg = widget.foreground ??
        (widget.active
            ? (widget.activeColor != null ? Colors.white : Colors.black)
            : Colors.white);
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedScale(
            scale: _pressed ? 0.9 : 1.0,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            child: Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
              child: Icon(widget.icon, color: fg, size: 26),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 72,
            child: Text(
              widget.label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// One emoji tile in the reaction sheet — big emoji, label under it, scales
/// down on press so it reads as a real button and not a decorative sticker.
class _FxButton extends StatefulWidget {
  final CallFxSound fx;
  final VoidCallback onTap;

  const _FxButton({required this.fx, required this.onTap});

  @override
  State<_FxButton> createState() => _FxButtonState();
}

class _FxButtonState extends State<_FxButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.9 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child:
                  Text(widget.fx.emoji, style: const TextStyle(fontSize: 28)),
            ),
            const SizedBox(height: 6),
            Text(
              widget.fx.label,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// One falling piece's motion parameters, randomized once at spawn.
class _FallingPiece {
  final double xFrac; // horizontal start position, 0..1 of overlay width
  final double delay; // 0..1 of the overlay's total lifetime, when it starts
  final double
      fallFrac; // 0..1, how much of the remaining time it takes to fall
  final double size;
  final double rotations; // full turns over its fall
  final double swayAmp;
  final double swayCycles;

  _FallingPiece(math.Random rnd)
      : xFrac = rnd.nextDouble(),
        delay = rnd.nextDouble() * 0.4,
        fallFrac = 0.5 + rnd.nextDouble() * 0.35,
        size = 22 + rnd.nextDouble() * 20,
        rotations = (rnd.nextDouble() - 0.5) * 3,
        swayAmp = 10 + rnd.nextDouble() * 22,
        swayCycles = 1 + rnd.nextDouble() * 1.5;
}

/// Falling-emoji rain triggered by an in-call reaction sound (Meet-style).
/// Runs once for [_kLifetime] then calls [onDone] so the caller can remove it
/// from the tree — this widget never loops or waits to be told to stop.
class _EmojiRainOverlay extends StatefulWidget {
  final String emoji;
  final VoidCallback onDone;

  const _EmojiRainOverlay(
      {super.key, required this.emoji, required this.onDone});

  @override
  State<_EmojiRainOverlay> createState() => _EmojiRainOverlayState();
}

class _EmojiRainOverlayState extends State<_EmojiRainOverlay>
    with SingleTickerProviderStateMixin {
  static const _kLifetime = Duration(milliseconds: 2400);
  late final AnimationController _ctrl;
  late final List<_FallingPiece> _pieces;

  @override
  void initState() {
    super.initState();
    final rnd = math.Random();
    _pieces = List.generate(16, (_) => _FallingPiece(rnd));
    _ctrl = AnimationController(vsync: this, duration: _kLifetime)
      ..forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, box) {
          final h = box.maxHeight;
          final w = box.maxWidth;
          return AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) {
              return Stack(
                children: [
                  for (final p in _pieces)
                    Builder(builder: (_) {
                      if (_ctrl.value < p.delay) return const SizedBox.shrink();
                      final t =
                          ((_ctrl.value - p.delay) / (1 - p.delay) / p.fallFrac)
                              .clamp(0.0, 1.0);
                      final y = -p.size + t * (h + p.size * 2);
                      final x = (p.xFrac * w +
                              math.sin(t * p.swayCycles * 2 * math.pi) *
                                  p.swayAmp)
                          .clamp(0.0, w - p.size);
                      final opacity = t > 0.82 ? (1 - (t - 0.82) / 0.18) : 1.0;
                      return Positioned(
                        left: x,
                        top: y,
                        child: Opacity(
                          opacity: opacity.clamp(0.0, 1.0),
                          child: Transform.rotate(
                            angle: t * p.rotations * 2 * math.pi,
                            child: Text(
                              widget.emoji,
                              style: TextStyle(fontSize: p.size),
                            ),
                          ),
                        ),
                      );
                    }),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
