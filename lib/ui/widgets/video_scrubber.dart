import 'package:flutter/material.dart';

/// A video progress bar that grows taller on hover/press and shows a
/// timestamp pill following the pointer above it — port of skiper91's
/// hover-time-display scrubbing, combined into skiper97-style full controls
/// elsewhere in the player. Mirrors [Slider]'s onChangeStart/onChanged/
/// onChangeEnd contract (milliseconds) so it drops into existing
/// pause-while-scrubbing logic unchanged.
class RlinkVideoScrubber extends StatefulWidget {
  final int positionMs;
  final int durationMs;
  final int? bufferedMs;
  final String Function(Duration) formatTime;
  final ValueChanged<int>? onChangeStart;
  final ValueChanged<int> onChanged;
  final ValueChanged<int>? onChangeEnd;

  const RlinkVideoScrubber({
    super.key,
    required this.positionMs,
    required this.durationMs,
    this.bufferedMs,
    required this.formatTime,
    this.onChangeStart,
    required this.onChanged,
    this.onChangeEnd,
  });

  @override
  State<RlinkVideoScrubber> createState() => _RlinkVideoScrubberState();
}

class _RlinkVideoScrubberState extends State<RlinkVideoScrubber> {
  static const _idleHeight = 3.0;
  static const _activeHeight = 7.0;
  static const _idleThumb = 6.0;
  static const _activeThumb = 9.0;

  bool _hovering = false;
  bool _dragging = false;
  double? _previewX; // local x within the track while hovering/dragging

  bool get _active => _hovering || _dragging;

  int _msAt(double x, double width) {
    final total = widget.durationMs;
    if (total <= 0 || width <= 0) return 0;
    return (x / width * total).round().clamp(0, total);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = widget.durationMs;
    final pos = widget.positionMs.clamp(0, total <= 0 ? 1 : total);
    final fraction = total > 0 ? pos / total : 0.0;
    final bufferedFraction =
        total > 0 && widget.bufferedMs != null ? (widget.bufferedMs! / total).clamp(0.0, 1.0) : null;

    return SizedBox(
      height: 40,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final trackHeight = _active ? _activeHeight : _idleHeight;
          final thumbSize = _active ? _activeThumb : _idleThumb;
          final previewX = (_previewX ?? fraction * width).clamp(0.0, width);
          final previewMs = _msAt(previewX, width);

          void handlePositionChange(Offset local, {required bool commit}) {
            final x = local.dx.clamp(0.0, width);
            setState(() => _previewX = x);
            if (commit) widget.onChanged(_msAt(x, width));
          }

          return MouseRegion(
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => setState(() {
              _hovering = false;
              if (!_dragging) _previewX = null;
            }),
            onHover: (e) {
              final box = context.findRenderObject() as RenderBox;
              final local = box.globalToLocal(e.position);
              setState(() => _previewX = local.dx.clamp(0.0, width));
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                setState(() => _dragging = true);
                widget.onChangeStart?.call(pos);
                handlePositionChange(d.localPosition, commit: true);
              },
              onTapUp: (_) {
                setState(() => _dragging = false);
                widget.onChangeEnd?.call(_msAt(_previewX ?? 0, width));
                if (!_hovering) setState(() => _previewX = null);
              },
              onHorizontalDragStart: (d) {
                setState(() => _dragging = true);
                widget.onChangeStart?.call(pos);
                handlePositionChange(d.localPosition, commit: true);
              },
              onHorizontalDragUpdate: (d) =>
                  handlePositionChange(d.localPosition, commit: true),
              onHorizontalDragEnd: (_) {
                setState(() => _dragging = false);
                widget.onChangeEnd?.call(_msAt(_previewX ?? 0, width));
                if (!_hovering) setState(() => _previewX = null);
              },
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  if (_active)
                    Positioned(
                      left: (previewX - 22).clamp(0.0, width - 44),
                      bottom: 26,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            widget.formatTime(Duration(milliseconds: previewMs)),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                  Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      curve: Curves.easeOut,
                      height: trackHeight,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(trackHeight / 2),
                      ),
                      child: Stack(
                        children: [
                          if (bufferedFraction != null)
                            FractionallySizedBox(
                              widthFactor: bufferedFraction,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.35),
                                  borderRadius:
                                      BorderRadius.circular(trackHeight / 2),
                                ),
                              ),
                            ),
                          FractionallySizedBox(
                            widthFactor: fraction.clamp(0.0, 1.0),
                            child: Container(
                              decoration: BoxDecoration(
                                color: cs.primary,
                                borderRadius:
                                    BorderRadius.circular(trackHeight / 2),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOut,
                    left: (fraction.clamp(0.0, 1.0) * width) - thumbSize / 2,
                    child: IgnorePointer(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        width: thumbSize,
                        height: thumbSize,
                        decoration: BoxDecoration(
                          color: cs.primary,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 3,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
