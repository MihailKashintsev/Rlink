import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/call_service.dart';
import 'avatar_widget.dart';
import '../screens/call_screen.dart';

/// Full-screen incoming-call UI for native platforms (Android/iOS/desktop) —
/// takes over the whole screen with large accept/decline controls, matching
/// how a real phone call looks, instead of the smaller modal card. Web uses
/// the lighter [IncomingCallOverlay] card instead (see main.dart's
/// `_showIncomingCallOverlay`) — a full-bleed takeover reads as an intrusive
/// popup in a browser tab the way it doesn't on a phone.
class IncomingCallFullscreenBanner extends StatefulWidget {
  final CallSessionInfo session;
  final String peerName;
  final int peerAvatarColor;
  final String peerAvatarEmoji;
  final String? peerAvatarImagePath;

  const IncomingCallFullscreenBanner({
    super.key,
    required this.session,
    required this.peerName,
    this.peerAvatarColor = 0xFF5C6BC0,
    this.peerAvatarEmoji = '',
    this.peerAvatarImagePath,
  });

  @override
  State<IncomingCallFullscreenBanner> createState() =>
      _IncomingCallFullscreenBannerState();
}

class _IncomingCallFullscreenBannerState
    extends State<IncomingCallFullscreenBanner>
    with TickerProviderStateMixin {
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    CallService.instance.phase.addListener(_onPhase);
  }

  void _onPhase() {
    final p = CallService.instance.phase.value;
    if (p == CallPhase.ended || p == CallPhase.failed || p == CallPhase.idle) {
      if (mounted && !_busy) {
        _busy = true;
        Navigator.of(context).maybePop();
      }
    }
  }

  @override
  void dispose() {
    CallService.instance.phase.removeListener(_onPhase);
    _ambient.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    if (_busy) return;
    setState(() => _busy = true);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CallScreen(
          session: widget.session,
          peerName: widget.peerName,
          peerAvatarColor: widget.peerAvatarColor,
          peerAvatarEmoji: widget.peerAvatarEmoji,
          peerAvatarImagePath: widget.peerAvatarImagePath,
        ),
      ),
    );
  }

  Future<void> _decline() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await CallService.instance.rejectIncoming(widget.session);
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pop();
  }

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

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.session.videoEnabled;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _ambientBackground(),
            SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 48),
                  Text(
                    isVideo ? 'Входящий видеозвонок' : 'Входящий аудиозвонок',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  _PulsingCallAvatarLarge(
                    controller: _pulseController,
                    peerName: widget.peerName,
                    peerAvatarColor: widget.peerAvatarColor,
                    peerAvatarEmoji: widget.peerAvatarEmoji,
                    peerAvatarImagePath: widget.peerAvatarImagePath,
                    isVideo: isVideo,
                  ),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      widget.peerName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Spacer(flex: 2),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 40, vertical: 32),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _CallActionButton(
                          busy: _busy,
                          onTap: _decline,
                          color: const Color(0xFFE53935),
                          icon: Icons.call_end_rounded,
                          label: 'Отклонить',
                        ),
                        _CallActionButton(
                          busy: _busy,
                          onTap: _accept,
                          color: const Color(0xFF43A047),
                          icon: isVideo
                              ? Icons.videocam_rounded
                              : Icons.call_rounded,
                          label: 'Принять',
                        ),
                      ],
                    ),
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

class _CallActionButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;
  final Color color;
  final IconData icon;
  final String label;

  const _CallActionButton({
    required this.busy,
    required this.onTap,
    required this.color,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: busy ? null : onTap,
            child: SizedBox(
              width: 76,
              height: 76,
              child: Icon(icon, color: Colors.white, size: 32),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      ],
    );
  }
}

class _PulsingCallAvatarLarge extends StatelessWidget {
  final Animation<double> controller;
  final String peerName;
  final int peerAvatarColor;
  final String peerAvatarEmoji;
  final String? peerAvatarImagePath;
  final bool isVideo;

  const _PulsingCallAvatarLarge({
    required this.controller,
    required this.peerName,
    required this.peerAvatarColor,
    required this.peerAvatarEmoji,
    required this.peerAvatarImagePath,
    required this.isVideo,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      height: 200,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          if (!MediaQuery.disableAnimationsOf(context))
            AnimatedBuilder(
              animation: controller,
              builder: (_, __) {
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    for (var i = 0; i < 3; i++)
                      _PulseRingLarge(
                        progress: (controller.value + i / 3) % 1,
                      ),
                  ],
                );
              },
            ),
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomRight,
            children: [
              AvatarWidget(
                initials: peerName.trim().isNotEmpty
                    ? peerName.trim().substring(0, 1).toUpperCase()
                    : '?',
                color: peerAvatarColor,
                emoji: peerAvatarEmoji,
                imagePath: peerAvatarImagePath,
                size: 148,
              ),
              Positioned(
                right: 2,
                bottom: 2,
                child: CircleAvatar(
                  radius: 22,
                  backgroundColor: Colors.white,
                  child: Icon(
                    isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                    size: 24,
                    color: Colors.black87,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PulseRingLarge extends StatelessWidget {
  final double progress;

  const _PulseRingLarge({required this.progress});

  @override
  Widget build(BuildContext context) {
    final opacity = (1 - progress).clamp(0.0, 1.0);
    return Transform.scale(
      scale: 0.78 + progress * 0.5,
      child: Opacity(
        opacity: opacity * 0.35,
        child: Container(
          width: 160,
          height: 160,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      ),
    );
  }
}
