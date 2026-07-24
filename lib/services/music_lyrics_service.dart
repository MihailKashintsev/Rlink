import 'package:flutter/foundation.dart';

import 'lyrics_db_service.dart';
import 'whisper_web_service.dart';

class LyricLine {
  final int startMs;
  final int endMs;
  final String text;
  const LyricLine(this.startMs, this.endMs, this.text);
}

enum LyricsPhase { idle, lookingUp, downloadingModel, transcribing, done }

/// Where the shown text came from — the UI labels ASR honestly as a guess.
enum LyricsSource { none, database, recognised }

class LyricsState {
  final String forUrl;
  final LyricsPhase phase;

  /// Model-download progress only. Transcription itself reports nothing —
  /// showing "100%" through the whole (multi-minute) recognition was the bug.
  final double progress;
  final String error;
  final List<LyricLine> lines;
  final LyricsSource source;

  const LyricsState({
    this.forUrl = '',
    this.phase = LyricsPhase.idle,
    this.progress = 0,
    this.error = '',
    this.lines = const [],
    this.source = LyricsSource.none,
  });

  bool get running =>
      phase == LyricsPhase.lookingUp ||
      phase == LyricsPhase.downloadingModel ||
      phase == LyricsPhase.transcribing;

  /// Index of the line covering [posMs], or the last one before it.
  int indexAt(int posMs) {
    var idx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startMs <= posMs) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }
}

/// Time-aligned transcription of a playing track (beta).
///
/// ponytail: one track at a time, result kept only for the current URL — a
/// persistent cache is worth adding once this stops being an experiment.
class MusicLyricsService {
  MusicLyricsService._();
  static final instance = MusicLyricsService._();

  final ValueNotifier<LyricsState> state = ValueNotifier(const LyricsState());
  String? _inFlight;

  Future<void> requestFor(String url, {String title = '', String artist = ''}) async {
    if (url.isEmpty) return;
    if (state.value.forUrl == url && !state.value.running) return;
    if (_inFlight == url) return;
    _inFlight = url;

    state.value = LyricsState(forUrl: url, phase: LyricsPhase.lookingUp);
    try {
      // 1) Real synced lyrics, if this song is a known one. Always better than
      //    recognising singing, and correctly timed by construction.
      final db = await LyricsDbService.instance
          .lookup(title: title, artist: artist);
      if (db != null && db.isNotEmpty) {
        state.value = LyricsState(
          forUrl: url,
          phase: LyricsPhase.done,
          source: LyricsSource.database,
          lines: [
            for (final l in db) LyricLine(l.startMs, l.startMs, l.text),
          ],
        );
        return;
      }

      // 2) Fall back to on-device recognition.
      state.value =
          LyricsState(forUrl: url, phase: LyricsPhase.downloadingModel);
      final whisper = WhisperWebService.instance;
      if (!whisper.isSupported) {
        state.value = LyricsState(
          forUrl: url,
          error: 'На этой платформе расшифровка песен пока недоступна',
        );
        return;
      }
      await whisper.init(onProgress: (loaded, total) {
        if (total <= 0) return;
        state.value = LyricsState(
          forUrl: url,
          phase: LyricsPhase.downloadingModel,
          progress: loaded / total,
        );
      });
      state.value =
          LyricsState(forUrl: url, phase: LyricsPhase.transcribing);
      // No forced language: songs are often not Russian, and forcing ru
      // turned lyrics into noise. Let Whisper detect it.
      final segments = await whisper.transcribeSegments(url, language: '');
      final lines = <LyricLine>[
        for (final s in segments)
          if ((s.text).trim().isNotEmpty)
            LyricLine(s.startMs, s.endMs, s.text.trim()),
      ];
      state.value = LyricsState(
        forUrl: url,
        phase: LyricsPhase.done,
        source: LyricsSource.recognised,
        lines: lines,
      );
    } catch (e) {
      state.value = LyricsState(
          forUrl: url, phase: LyricsPhase.done, error: 'Не получилось: $e');
    } finally {
      _inFlight = null;
    }
  }
}
