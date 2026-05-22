import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../services/app_settings.dart';
import '../../services/call_history_service.dart';
import '../../services/local_transcription_service.dart';
import '../../services/voice_service.dart';
import '../../utils/video_controller_for_path.dart';
import '../../utils/web_file_store.dart';
import '../widgets/avatar_widget.dart';

class CallRecordingPlaybackScreen extends StatefulWidget {
  final CallHistoryEntry entry;
  const CallRecordingPlaybackScreen({super.key, required this.entry});

  @override
  State<CallRecordingPlaybackScreen> createState() =>
      _CallRecordingPlaybackScreenState();
}

class _CallRecordingPlaybackScreenState
    extends State<CallRecordingPlaybackScreen> {
  VideoPlayerController? _videoCtrl;
  bool _isVideo = false;
  bool _playing = false;
  bool _transcribing = false;
  String? _transcriptText;
  List<_SpeakerSegment> _speakerSegments = [];
  int _highlightedSegment = -1;
  Timer? _positionTimer;
  String? _videoPlaybackUrl;

  CallHistoryEntry get _entry => widget.entry;

  @override
  void initState() {
    super.initState();
    unawaited(_initPlayback());
    _loadExistingTranscript();
  }

  void _loadExistingTranscript() {
    final t = _entry.transcript;
    if (t != null && t.isNotEmpty) {
      _transcriptText = t;
      final labels = _entry.transcriptSpeakerLabels;
      if (labels != null && labels.isNotEmpty) {
        try {
          final list = jsonDecode(labels) as List;
          _speakerSegments = list
              .map((e) => _SpeakerSegment(
                    speaker: e['speaker'] as String? ?? 'me',
                    text: e['text'] as String? ?? '',
                  ))
              .toList();
        } catch (_) {}
      }
    }
  }

  Future<void> _initPlayback() async {
    final path = _entry.recordingPath;
    if (path == null || path.isEmpty || !localFileExistsForPath(path)) {
      return;
    }
    _isVideo = _entry.video || path.endsWith('.mp4');
    if (_isVideo) {
      final playbackPath = await _playbackPathForRecording();
      if (playbackPath == null || !mounted) return;
      _videoPlaybackUrl = playbackPath;
      _videoCtrl = videoControllerForPath(playbackPath);
      await _videoCtrl!.initialize();
      if (!mounted) return;
      setState(() {});
      _videoCtrl!.addListener(_onVideoState);
    }
  }

  void _onVideoState() {
    if (!mounted) {
      return;
    }
    final v = _videoCtrl;
    if (v == null) {
      return;
    }
    final wasPlaying = _playing;
    _playing = v.value.isPlaying;
    if (wasPlaying != _playing && mounted) {
      setState(() {});
    }
    if (_speakerSegments.isNotEmpty && v.value.isPlaying) {
      final segIdx =
          (v.value.position.inSeconds ~/ 3) % _speakerSegments.length;
      if (segIdx != _highlightedSegment) {
        setState(() => _highlightedSegment = segIdx);
      }
    }
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    _videoCtrl?.dispose();
    super.dispose();
  }

  Future<void> _togglePlayPause() async {
    final path = _entry.recordingPath;
    if (path == null || path.isEmpty || !localFileExistsForPath(path)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Файл записи не найден')));
      }
      return;
    }
    if (_isVideo && _videoCtrl != null) {
      final v = _videoCtrl!;
      v.value.isPlaying ? await v.pause() : await v.play();
      if (mounted) {
        setState(() => _playing = v.value.isPlaying);
      }
    } else {
      if (_playing) {
        await VoiceService.instance.stopPlayback();
        if (mounted) {
          setState(() => _playing = false);
        }
      } else {
        final playbackPath = await _playbackPathForRecording();
        if (playbackPath == null) {
          return;
        }
        await VoiceService.instance.play(playbackPath, title: 'Запись звонка');
        if (mounted) {
          setState(() => _playing = true);
        }
        _positionTimer?.cancel();
        _positionTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
          if (!mounted) {
            return;
          }
          final s = VoiceService.instance.playbackSession.value;
          if (s == null || s.path != playbackPath) {
            if (mounted) {
              setState(() => _playing = false);
            }
            _positionTimer?.cancel();
          }
        });
      }
    }
  }

  Future<void> _transcribeRecording() async {
    final path = _entry.recordingPath;
    if (path == null || path.isEmpty || !localFileExistsForPath(path)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Файл записи не найден')));
      }
      return;
    }
    if (!LocalTranscriptionService.instance.isSupported) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Локальная расшифровка доступна на iOS, macOS, Android и Windows')));
      }
      return;
    }
    setState(() => _transcribing = true);
    try {
      final transcriptionLanguage =
          LocalTranscriptionService.mapLocaleToWhisperLanguage(
              AppSettings.instance.locale);
      final pathForTranscribe = await _playbackPathForRecording();
      if (pathForTranscribe == null) {
        throw StateError('Файл записи не найден');
      }
      final text = await LocalTranscriptionService.instance
          .transcribeFile(pathForTranscribe, language: transcriptionLanguage);
      final segments = _simpleDiarization(text);
      if (!mounted) return;
      await CallHistoryService.instance.setTranscript(_entry.id, text,
          speakerLabels: jsonEncode(segments
              .map((s) => {'speaker': s.speaker, 'text': s.text})
              .toList()));
      setState(() {
        _transcriptText = text;
        _speakerSegments = segments;
        _transcribing = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Не удалось расшифровать: $e'),
            backgroundColor: Colors.red));
        setState(() => _transcribing = false);
      }
    }
  }

  List<_SpeakerSegment> _simpleDiarization(String text) {
    final sentences = text
        .split(RegExp(r'(?<=[.!?])\s+'))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (sentences.isEmpty) return [];
    return List.generate(
        sentences.length,
        (i) => _SpeakerSegment(
            speaker: i.isEven ? 'me' : 'peer', text: sentences[i].trim()));
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  String _recordingMimeType() {
    final path = _entry.recordingPath ?? '';
    if (_entry.video) {
      return path.endsWith('.mp4') ? 'video/mp4' : 'video/webm';
    }
    return path.endsWith('.m4a') || path.endsWith('.mp4')
        ? 'audio/mp4'
        : 'audio/webm';
  }

  String _downloadFileName() {
    final path = _entry.recordingPath ?? '';
    final ext = path.endsWith('.mp4')
        ? 'mp4'
        : path.endsWith('.m4a')
            ? 'm4a'
            : 'webm';
    return 'rlink_call_${_entry.endedAtMs}.$ext';
  }

  Future<String?> _playbackPathForRecording() async {
    final path = _entry.recordingPath;
    if (path == null || path.isEmpty) {
      return null;
    }
    if (kIsWeb && isWebStoredFile(path)) {
      return webStoredFileObjectUrl(path, mimeType: _recordingMimeType());
    }
    return _videoPlaybackUrl ?? path;
  }

  Future<void> _downloadRecording() async {
    final path = _entry.recordingPath;
    if (path == null || path.isEmpty || !localFileExistsForPath(path)) {
      return;
    }
    final fileName = _downloadFileName();
    if (kIsWeb) {
      await downloadWebFile(
        path,
        fileName: fileName,
        mimeType: _recordingMimeType(),
      );
    } else {
      await copyLocalFileToDownloads(path, fileName);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Запись сохранена')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasRecording = _entry.recordingPath != null &&
        _entry.recordingPath!.isNotEmpty &&
        localFileExistsForPath(_entry.recordingPath!);

    return Scaffold(
      appBar: AppBar(title: Text(_entry.peerDisplayName)),
      body: Column(children: [
        if (_isVideo && _videoCtrl != null && _videoCtrl!.value.isInitialized)
          AspectRatio(
            aspectRatio: _videoCtrl!.value.aspectRatio,
            child: Stack(alignment: Alignment.center, children: [
              VideoPlayer(_videoCtrl!),
              if (!_playing)
                IconButton.filled(
                    icon: const Icon(Icons.play_arrow, size: 48),
                    onPressed: _togglePlayPause),
            ]),
          )
        else
          Container(
              height: 160,
              color: cs.surfaceContainerHighest,
              child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                AvatarWidget(
                    initials: _entry.peerDisplayName.isNotEmpty
                        ? _entry.peerDisplayName[0].toUpperCase()
                        : '?',
                    color: 0xFF607D8B,
                    size: 56),
                const SizedBox(height: 10),
                Text(_entry.peerDisplayName,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
                Text(
                    '${_entry.incoming ? 'Входящий' : 'Исходящий'} · ${_entry.video ? 'Видео' : 'Аудио'} · ${_fmt(_entry.duration)}',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ]))),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              if (hasRecording) ...[
                ElevatedButton.icon(
                    onPressed: _togglePlayPause,
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                    label: Text(_playing
                        ? 'Пауза'
                        : _isVideo
                            ? 'Смотреть'
                            : 'Слушать')),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Скачать запись',
                  onPressed: _downloadRecording,
                  icon: const Icon(Icons.download_outlined),
                ),
                const SizedBox(width: 8),
              ],
              if (_transcriptText == null || _transcriptText!.isEmpty)
                ElevatedButton.icon(
                    onPressed: _transcribing ? null : _transcribeRecording,
                    icon: _transcribing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.transcribe),
                    label: Text(
                        _transcribing ? 'Расшифровка...' : 'Расшифровать')),
            ])),
        const Divider(),
        if (_transcriptText != null && _transcriptText!.isNotEmpty)
          Expanded(
              child: ListView(padding: const EdgeInsets.all(16), children: [
            Text('Расшифровка',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.primary)),
            const SizedBox(height: 8),
            if (_speakerSegments.isNotEmpty)
              ..._speakerSegments.asMap().entries.map((e) {
                final seg = e.value;
                final isMe = seg.speaker == 'me';
                final hl = e.key == _highlightedSegment;
                return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        color: hl
                            ? cs.primaryContainer.withValues(alpha: 0.5)
                            : isMe
                                ? cs.tertiaryContainer.withValues(alpha: 0.3)
                                : cs.secondaryContainer.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(10),
                        border: hl
                            ? Border.all(color: cs.primary, width: 1.5)
                            : null),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(isMe ? 'Вы' : _entry.peerDisplayName,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: isMe ? cs.tertiary : cs.secondary)),
                          const SizedBox(height: 4),
                          Text(seg.text,
                              style:
                                  const TextStyle(fontSize: 14, height: 1.4)),
                        ]));
              })
            else
              Text(_transcriptText!,
                  style: const TextStyle(fontSize: 14, height: 1.5)),
          ]))
        else
          Expanded(
              child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.mic_none,
                size: 48, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
                hasRecording
                    ? 'Нажмите «Расшифровать» для распознавания речи'
                    : 'Запись не сохранилась',
                style: TextStyle(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.6))),
          ]))),
      ]),
    );
  }
}

class _SpeakerSegment {
  final String speaker;
  final String text;
  const _SpeakerSegment({required this.speaker, required this.text});
}
