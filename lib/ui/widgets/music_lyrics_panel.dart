import 'package:flutter/material.dart';

import '../../services/music_lyrics_service.dart';
import '../../services/voice_service.dart';

/// Live transcription under the player (beta). Not real lyrics: the track is
/// run through on-device speech recognition, so singing over instruments is
/// recognised far less reliably than speech — the UI says so out loud.
class MusicLyricsPanel extends StatefulWidget {
  final String url;
  final String title;
  final String artist;
  const MusicLyricsPanel({
    super.key,
    required this.url,
    required this.title,
    this.artist = '',
  });

  @override
  State<MusicLyricsPanel> createState() => _MusicLyricsPanelState();
}

class _MusicLyricsPanelState extends State<MusicLyricsPanel> {
  bool _open = false;
  final _scroll = ScrollController();
  int _lastIdx = -1;

  static const _lineExtent = 26.0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Keep the current line in view — otherwise the highlight scrolls out and
  /// the panel looks like it isn't following the song at all.
  void _followActive(int idx) {
    if (idx < 0 || idx == _lastIdx || !_scroll.hasClients) return;
    _lastIdx = idx;
    final target = (idx * _lineExtent) - 30;
    _scroll.animateTo(
      target.clamp(0.0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final svc = MusicLyricsService.instance;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton.icon(
              onPressed: () {
                setState(() => _open = !_open);
                if (_open) {
                  svc.requestFor(widget.url,
                      title: widget.title, artist: widget.artist);
                }
              },
              icon: Icon(_open ? Icons.expand_more : Icons.lyrics_outlined,
                  size: 18),
              label: const Text('Текст (бета)', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        if (_open)
          ValueListenableBuilder<LyricsState>(
            valueListenable: svc.state,
            builder: (_, st, __) {
              if (st.forUrl != widget.url) {
                return _note(cs, 'Готовим расшифровку…');
              }
              if (st.error.isNotEmpty) return _note(cs, st.error);
              if (st.phase == LyricsPhase.lookingUp) {
                return _note(cs, 'Ищем текст песни…');
              }
              if (st.phase == LyricsPhase.downloadingModel) {
                return _note(
                    cs, 'Загружаем модель… ${(st.progress * 100).round()}%');
              }
              if (st.phase == LyricsPhase.transcribing) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Распознаём трек — это занимает несколько минут',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                );
              }
              if (st.lines.isEmpty) {
                return _note(cs, 'Не удалось разобрать слова в этом треке');
              }
              return ValueListenableBuilder<double>(
                valueListenable: VoiceService.instance.playProgress,
                builder: (_, progress, ___) {
                  final dur = VoiceService.instance.playDuration.value;
                  final posMs =
                      (dur.inMilliseconds * progress.clamp(0.0, 1.0)).round();
                  final idx = st.indexAt(posMs);
                  WidgetsBinding.instance
                      .addPostFrameCallback((_) => _followActive(idx));
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (st.source == LyricsSource.recognised)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            'Текста нет в базе — распознано на слух, возможны ошибки',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 10,
                                color:
                                    cs.onSurfaceVariant.withValues(alpha: 0.8)),
                          ),
                        ),
                      SizedBox(
                        height: 92,
                        child: ListView.builder(
                          controller: _scroll,
                          itemExtent: _lineExtent,
                          itemCount: st.lines.length,
                          itemBuilder: (_, i) {
                            final active = i == idx;
                            return AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 200),
                              style: TextStyle(
                                fontSize: active ? 15 : 13,
                                height: 1.4,
                                fontWeight:
                                    active ? FontWeight.w700 : FontWeight.w400,
                                color: active
                                    ? cs.primary
                                    : cs.onSurfaceVariant
                                        .withValues(alpha: 0.7),
                              ),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 2),
                                child: Text(st.lines[i].text,
                                    textAlign: TextAlign.center),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
      ],
    );
  }

  Widget _note(ColorScheme cs, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      );
}
