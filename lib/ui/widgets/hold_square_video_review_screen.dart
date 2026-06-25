import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../../services/embedded_video_pause_bus.dart';
import '../../utils/web_video_frames.dart';
import 'square_video_recording_widgets.dart';

/// Предпросмотр «видеоквадратика» перед отправкой (удержание или полноэкранный рекордер).
/// [allowTrim] — показать ползунок обрезки (обычно true).
class HoldSquareVideoReviewScreen extends StatefulWidget {
  final String videoPath;
  final bool allowTrim;

  /// Preview-only: shown while recording is paused so the user can watch what
  /// they've recorded so far, then go back and resume. No trim / send.
  final bool previewOnly;

  /// Square crop preview (square video recordings). When false, the video is
  /// shown in its natural aspect ratio (picked / arbitrary videos).
  final bool square;

  const HoldSquareVideoReviewScreen({
    super.key,
    required this.videoPath,
    required this.allowTrim,
    this.previewOnly = false,
    this.square = true,
  });

  @override
  State<HoldSquareVideoReviewScreen> createState() =>
      _HoldSquareVideoReviewScreenState();
}

class _HoldSquareVideoReviewScreenState
    extends State<HoldSquareVideoReviewScreen> {
  VideoPlayerController? _player;
  bool _ready = false;
  bool _busy = false;
  double _durationSec = 1;
  double _rangeStart = 0;
  double _rangeEnd = 1;
  int _embedPauseGen = 0;

  void _onEmbedPauseBus() {
    if (!mounted) return;
    final g = EmbeddedVideoPauseBus.instance.generation.value;
    if (g != _embedPauseGen) {
      _embedPauseGen = g;
      try {
        _player?.pause();
      } catch (_) {}
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _embedPauseGen = EmbeddedVideoPauseBus.instance.generation.value;
    EmbeddedVideoPauseBus.instance.generation.addListener(_onEmbedPauseBus);
    final c = kIsWeb && _isInlineWebUri(widget.videoPath)
        ? VideoPlayerController.networkUrl(Uri.parse(widget.videoPath))
        : VideoPlayerController.file(File(widget.videoPath));
    _player = c;
    c.initialize().then((_) {
      if (!mounted) return;
      final d = c.value.duration.inMilliseconds / 1000.0;
      final dur = d > 0.05 ? d : 0.05;
      setState(() {
        _durationSec = dur;
        _rangeStart = 0;
        _rangeEnd = dur;
        _ready = true;
      });
      c.setLooping(true);
      c.play();
    });
  }

  @override
  void dispose() {
    EmbeddedVideoPauseBus.instance.generation.removeListener(_onEmbedPauseBus);
    _player?.dispose();
    super.dispose();
  }

  void _onRangeChanged(RangeValues v) {
    final p = _player;
    if (p == null || !_ready) return;
    setState(() {
      _rangeStart = v.start.clamp(0.0, _durationSec);
      _rangeEnd = v.end.clamp(0.0, _durationSec);
      if (_rangeEnd - _rangeStart < 0.25) {
        if (_rangeEnd >= _durationSec) {
          _rangeStart = (_rangeEnd - 0.25).clamp(0.0, _durationSec);
        } else {
          _rangeEnd = (_rangeStart + 0.25).clamp(0.0, _durationSec);
        }
      }
    });
    p.seekTo(Duration(milliseconds: (_rangeStart * 1000).round()));
  }

  bool get _effectivelyFullTrim {
    return _rangeStart <= 0.05 && _rangeEnd >= _durationSec - 0.05;
  }

  Future<void> _send() async {
    if (_busy || !_ready) return;
    final nav = Navigator.of(context);

    if (kIsWeb) {
      // Browsers can't re-encode → send the original (trimming is app-only).
      nav.pop(widget.videoPath);
      return;
    }

    if (!widget.allowTrim || _effectivelyFullTrim) {
      nav.pop(widget.videoPath);
      return;
    }

    setState(() => _busy = true);
    try {
      final int st = _rangeStart
          .floor()
          .clamp(0, math.max(0, _durationSec.floor()))
          .toInt();
      var dur = (_rangeEnd - _rangeStart).ceil();
      if (dur < 1) dur = 1;
      final maxFromStart = (_durationSec - st).ceil();
      if (dur > maxFromStart) dur = math.max(1, maxFromStart);

      final info = await VideoCompress.compressVideo(
        widget.videoPath,
        quality: VideoQuality.MediumQuality,
        includeAudio: true,
        deleteOrigin: false,
        startTime: st,
        duration: dur,
      );
      if (!mounted) return;
      if (info?.path == null || info!.path!.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось обрезать видео')),
        );
        setState(() => _busy = false);
        return;
      }
      nav.pop(info.path!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Обрезка: $e')),
        );
        setState(() => _busy = false);
      }
    }
  }

  static bool _isInlineWebUri(String value) =>
      value.startsWith('data:') ||
      value.startsWith('blob:') ||
      value.startsWith('http://') ||
      value.startsWith('https://');

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = _player;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.previewOnly ? 'Запись' : 'Просмотр'),
        leading: IconButton(
          icon: Icon(widget.previewOnly ? Icons.arrow_back : Icons.close),
          tooltip: widget.previewOnly ? 'Назад к записи' : 'Отмена',
          onPressed: _busy ? null : () => Navigator.pop(context),
        ),
      ),
      body: !_ready || p == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (ctx, bc) {
                final side = math
                    .min(
                      squareVideoPreviewSize(ctx),
                      math.min(bc.maxWidth, bc.maxHeight) - 8,
                    )
                    .clamp(200.0, 360.0);
                return Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: widget.square
                            ? SizedBox(
                                width: side,
                                height: side,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(20),
                                  child: FittedBox(
                                    fit: BoxFit.cover,
                                    alignment: Alignment.center,
                                    child: SizedBox(
                                      width: p.value.size.width,
                                      height: p.value.size.height,
                                      child: VideoPlayer(p),
                                    ),
                                  ),
                                ),
                              )
                            : Padding(
                                padding: const EdgeInsets.all(8),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: AspectRatio(
                                    aspectRatio: p.value.aspectRatio > 0
                                        ? p.value.aspectRatio
                                        : 16 / 9,
                                    child: VideoPlayer(p),
                                  ),
                                ),
                              ),
                      ),
                    ),
                    if (widget.allowTrim && !widget.previewOnly) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          kIsWeb
                              ? 'Предпросмотр перед отправкой'
                              : 'Потяните за края, чтобы обрезать, или отправьте целиком',
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                      _FilmstripTrimBar(
                        videoPath: widget.videoPath,
                        durationSec: _durationSec,
                        start: _rangeStart,
                        end: _rangeEnd,
                        onChanged: _busy ? (_) {} : _onRangeChanged,
                        readOnly: kIsWeb, // web can't cut → frames are visual only
                      ),
                    ] else
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          widget.previewOnly
                              ? 'Это снято на данный момент. Вернитесь, чтобы продолжить запись.'
                              : 'Проверьте кадр и нажмите «Отправить»',
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _busy
                                ? null
                                : (widget.previewOnly
                                    ? () => Navigator.pop(context)
                                    : _send),
                            child: Text(widget.previewOnly
                                ? 'Продолжить запись'
                                : (_busy ? 'Обработка…' : 'Отправить')),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

/// A filmstrip trim bar: a row of extracted frame thumbnails with two draggable
/// handles. The region outside the selection is dimmed. Native only (uses
/// VideoCompress thumbnails); the web path keeps the plain RangeSlider.
class _FilmstripTrimBar extends StatefulWidget {
  final String videoPath;
  final double durationSec;
  final double start;
  final double end;
  final ValueChanged<RangeValues> onChanged;
  final bool readOnly;

  const _FilmstripTrimBar({
    required this.videoPath,
    required this.durationSec,
    required this.start,
    required this.end,
    required this.onChanged,
    this.readOnly = false,
  });

  @override
  State<_FilmstripTrimBar> createState() => _FilmstripTrimBarState();
}

class _FilmstripTrimBarState extends State<_FilmstripTrimBar> {
  static const _frames = 8;
  static const _barH = 56.0;
  static const _handleW = 16.0;
  List<Uint8List?> _thumbs = List<Uint8List?>.filled(_frames, null);

  @override
  void initState() {
    super.initState();
    _extract();
  }

  Future<void> _extract() async {
    if (kIsWeb) {
      // Web: extract frames via a hidden <video> + <canvas>.
      try {
        final frames =
            await webVideoThumbnails(widget.videoPath, count: _frames);
        if (!mounted || frames.isEmpty) return;
        setState(() {
          for (var i = 0; i < _frames && i < frames.length; i++) {
            _thumbs[i] = frames[i];
          }
        });
      } catch (_) {}
      return;
    }
    for (var i = 0; i < _frames; i++) {
      final pos =
          (widget.durationSec * 1000 * (i + 0.5) / _frames).round();
      Uint8List? b;
      try {
        b = await VideoCompress.getByteThumbnail(
          widget.videoPath,
          quality: 40,
          position: pos,
        );
      } catch (_) {
        b = null;
      }
      if (!mounted) return;
      setState(() => _thumbs[i] = b);
    }
  }

  String _fmt(double s) => '${s.toStringAsFixed(1)} с';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dur = widget.durationSec <= 0 ? 1.0 : widget.durationSec;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (ctx, c) {
              final w = c.maxWidth;
              double xOf(double t) =>
                  (t / dur).clamp(0.0, 1.0) * (w - _handleW) + _handleW / 2;
              final lx = xOf(widget.start);
              final rx = xOf(widget.end);
              final span = (w - _handleW);

              void dragStartBy(double ddx) {
                final dt = span <= 0 ? 0.0 : ddx / span * dur;
                final t = (widget.start + dt).clamp(0.0, widget.end - 0.25);
                widget.onChanged(RangeValues(t, widget.end));
              }

              void dragEndBy(double ddx) {
                final dt = span <= 0 ? 0.0 : ddx / span * dur;
                final t = (widget.end + dt).clamp(widget.start + 0.25, dur);
                widget.onChanged(RangeValues(widget.start, t));
              }

              final filmstrip = Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Row(
                    children: [
                      for (final t in _thumbs)
                        Expanded(
                          child: t == null
                              ? Container(color: const Color(0xFF222222))
                              : Image.memory(t,
                                  fit: BoxFit.cover,
                                  height: _barH,
                                  gaplessPlayback: true),
                        ),
                    ],
                  ),
                ),
              );
              if (widget.readOnly) {
                // Frames only (web can't cut — visual timeline).
                return SizedBox(
                  height: _barH,
                  width: w,
                  child: Stack(children: [filmstrip]),
                );
              }
              return SizedBox(
                height: _barH,
                width: w,
                child: Stack(
                  children: [
                    filmstrip,
                    // Dim outside selection.
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: lx,
                      child: Container(color: Colors.black.withValues(alpha: 0.55)),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      left: rx,
                      child: Container(color: Colors.black.withValues(alpha: 0.55)),
                    ),
                    // Selection border.
                    Positioned(
                      left: lx,
                      width: rx - lx,
                      top: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.symmetric(
                              horizontal:
                                  BorderSide(color: cs.primary, width: 3),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Left handle.
                    _handle(lx - _handleW / 2, cs.primary,
                        (d) => dragStartBy(d.delta.dx)),
                    // Right handle.
                    _handle(rx - _handleW / 2, cs.primary,
                        (d) => dragEndBy(d.delta.dx)),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 6),
          if (widget.readOnly)
            Text('Обрезка видео доступна в приложении',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(widget.start),
                    style:
                        TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                Text('${_fmt(widget.end - widget.start)} выбрано',
                    style: TextStyle(
                        fontSize: 12,
                        color: cs.primary,
                        fontWeight: FontWeight.w600)),
                Text(_fmt(widget.end),
                    style:
                        TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _handle(double left, Color color, GestureDragUpdateCallback onDrag) {
    return Positioned(
      left: left,
      top: 0,
      bottom: 0,
      width: _handleW,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: onDrag,
        child: Center(
          child: Container(
            width: _handleW,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(Icons.drag_indicator,
                size: 14, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
