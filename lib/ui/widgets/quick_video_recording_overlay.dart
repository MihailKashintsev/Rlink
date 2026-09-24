import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show ValueListenable, kIsWeb;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../l10n/app_l10n.dart';
import '../../models/quick_video.dart';
import 'square_video_recording_widgets.dart';
import 'telegram_media_record_button.dart' show RecordKeep;

/// Слой поверх переписки во время записи быстрого видео: затемняет чат, по
/// центру — камера в выбранной форме, слева над полем ввода — вспышка и
/// переворот камеры. Поле ввода остаётся видимым (слой лежит только над чатом).
class QuickVideoRecordingOverlay extends StatefulWidget {
  final CameraController controller;
  final QuickVideoShape shape;
  final ValueListenable<double> seconds;
  final double maxSeconds;
  final bool paused;
  final VideoPlayerController? pausePreview;
  final bool isFront;
  final bool flashOn;
  final bool canFlip;
  final bool switching;
  final VoidCallback onToggleFlash;
  final VoidCallback onFlip;

  const QuickVideoRecordingOverlay({
    super.key,
    required this.controller,
    required this.shape,
    required this.seconds,
    required this.maxSeconds,
    required this.paused,
    required this.pausePreview,
    required this.isFront,
    required this.flashOn,
    required this.canFlip,
    required this.switching,
    required this.onToggleFlash,
    required this.onFlip,
  });

  @override
  State<QuickVideoRecordingOverlay> createState() =>
      _QuickVideoRecordingOverlayState();
}

class _QuickVideoRecordingOverlayState
    extends State<QuickVideoRecordingOverlay>
    with SingleTickerProviderStateMixin {
  // Flip animation: 0→0.5 turns the frame edge-on (old camera goes away),
  // then 0.5→1 turns it back from the other side once the new camera is up.
  late final AnimationController _flip = AnimationController(vsync: this);
  bool _awaitingSwitch = false;

  @override
  void dispose() {
    _flip.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant QuickVideoRecordingOverlay old) {
    super.didUpdateWidget(old);
    if (_awaitingSwitch && old.switching && !widget.switching) {
      _awaitingSwitch = false;
      _flip.animateTo(1,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic)
        ..whenComplete(() {
          if (mounted) _flip.value = 0;
        });
    }
  }

  void _onFlipTap() {
    if (widget.switching || _awaitingSwitch) return;
    _awaitingSwitch = true;
    // The platform view of the web camera can't live inside a Transform.
    if (!kIsWeb) {
      _flip.animateTo(0.5,
          duration: const Duration(milliseconds: 180), curve: Curves.easeIn);
    }
    widget.onFlip();
    if (kIsWeb) _awaitingSwitch = false;
  }

  @override
  Widget build(BuildContext context) {
    final white = widget.flashOn && widget.isFront;
    return LayoutBuilder(
      builder: (context, c) {
        final side = math.max(
            120.0, math.min(c.maxWidth * 0.8, math.min(c.maxHeight * 0.78, 380.0)));
        Widget frame = SquareVideoFramedCameraView(
          controller: widget.controller,
          squareSize: side,
          isRecording: true,
          recordingSeconds: widget.seconds,
          maxDuration: widget.maxSeconds,
          recordingPaused: widget.paused,
          isPaused: widget.paused,
          pausePreview: widget.pausePreview,
          shape: widget.shape,
          showTimer: false,
        );
        if (!kIsWeb) {
          frame = AnimatedBuilder(
            animation: _flip,
            builder: (_, child) {
              final v = _flip.value;
              final angle = (v <= 0.5 ? v : v - 1) * math.pi;
              return Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0012)
                  ..rotateY(angle),
                child: child,
              );
            },
            child: frame,
          );
        }
        return Stack(
          children: [
            // Scrim: dims the chat (bright white for front-camera "flash").
            Positioned.fill(
              child: AbsorbPointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  color: white
                      ? Colors.white
                      : Colors.black.withValues(alpha: 0.72),
                ),
              ),
            ),
            Center(child: frame),
            Positioned(
              left: 12,
              bottom: 12,
              child: RecordKeep(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _RoundButton(
                      tooltip: AppL10n.t('Вспышка'),
                      icon: widget.flashOn
                          ? Icons.flash_on_rounded
                          : Icons.flash_off_rounded,
                      active: widget.flashOn,
                      onTap: widget.onToggleFlash,
                    ),
                    if (widget.canFlip) ...[
                      const SizedBox(width: 10),
                      _RoundButton(
                        tooltip: AppL10n.t('Перевернуть камеру'),
                        icon: Icons.flip_camera_ios_rounded,
                        onTap: _onFlipTap,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? Colors.amber : Colors.black.withValues(alpha: 0.6),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 46,
            height: 46,
            child: Icon(icon,
                size: 22, color: active ? Colors.black : Colors.white),
          ),
        ),
      ),
    );
  }
}
