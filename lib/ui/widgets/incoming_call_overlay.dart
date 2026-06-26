import 'package:flutter/material.dart';
import '../../l10n/app_l10n.dart';

import '../../services/call_service.dart';
import 'avatar_widget.dart';
import 'animated_transitions.dart';
import '../screens/call_screen.dart';

class IncomingCallOverlay extends StatefulWidget {
  final CallSessionInfo session;
  final String peerName;
  final int peerAvatarColor;
  final String peerAvatarEmoji;
  final String? peerAvatarImagePath;

  const IncomingCallOverlay({
    super.key,
    required this.session,
    required this.peerName,
    this.peerAvatarColor = 0xFF5C6BC0,
    this.peerAvatarEmoji = '',
    this.peerAvatarImagePath,
  });

  @override
  State<IncomingCallOverlay> createState() => _IncomingCallOverlayState();
}

class _IncomingCallOverlayState extends State<IncomingCallOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    // Auto-dismiss the invite if the caller cancels / the call ends / times out.
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

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.session.videoEnabled;
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.86),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: OneShotSlideFade(
              beginOffset: const Offset(0, 0.08),
              duration: const Duration(milliseconds: 320),
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .outline
                        .withValues(alpha: 0.25),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PulsingCallAvatar(
                      controller: _pulseController,
                      peerName: widget.peerName,
                      peerAvatarColor: widget.peerAvatarColor,
                      peerAvatarEmoji: widget.peerAvatarEmoji,
                      peerAvatarImagePath: widget.peerAvatarImagePath,
                      isVideo: isVideo,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Входящий ${isVideo ? 'видеозвонок' : 'аудиозвонок'}',
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      widget.peerName,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _busy ? null : _decline,
                            icon: const Icon(Icons.call_end_rounded,
                                color: Colors.red),
                            label: Text(AppL10n.t('common_decline')),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _busy ? null : _accept,
                            icon: const Icon(Icons.call_rounded),
                            label: Text(AppL10n.t('common_accept')),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PulsingCallAvatar extends StatelessWidget {
  final Animation<double> controller;
  final String peerName;
  final int peerAvatarColor;
  final String peerAvatarEmoji;
  final String? peerAvatarImagePath;
  final bool isVideo;

  const _PulsingCallAvatar({
    required this.controller,
    required this.peerName,
    required this.peerAvatarColor,
    required this.peerAvatarEmoji,
    required this.peerAvatarImagePath,
    required this.isVideo,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 132,
      height: 120,
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
                      _PulseRing(
                        progress: (controller.value + i / 3) % 1,
                        color: cs.primary,
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
                size: 88,
              ),
              Positioned(
                right: -2,
                bottom: -2,
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: cs.primary,
                  child: Icon(
                    isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                    size: 20,
                    color: cs.onPrimary,
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

class _PulseRing extends StatelessWidget {
  final double progress;
  final Color color;

  const _PulseRing({required this.progress, required this.color});

  @override
  Widget build(BuildContext context) {
    final opacity = (1 - progress).clamp(0.0, 1.0);
    return Transform.scale(
      scale: 0.72 + progress * 0.52,
      child: Opacity(
        opacity: opacity * 0.32,
        child: Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
        ),
      ),
    );
  }
}
