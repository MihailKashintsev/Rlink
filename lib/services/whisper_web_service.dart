// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'whisper_web_service_stub.dart'
    if (dart.library.js) 'whisper_web_service_web.dart';

/// Web-реализация расшифровки через transformers.js (ONNX):
/// whisper-small на WebGPU, откат на whisper-tiny/WASM.
/// Использует JS-объект window.rlinkWhisper (whisper_web.js).
class WhisperWebService {
  WhisperWebService._();
  static final WhisperWebService instance = WhisperWebService._();

  bool get isSupported => kIsWeb;

  bool get isReady => impl.isReady;

  String? get lastError => impl.lastError;

  Future<void> init({void Function(int loaded, int total)? onProgress}) async {
    await impl.init(onProgress: onProgress);
  }

  Future<String> transcribe(String audioPath, {String language = 'ru'}) async {
    return impl.transcribe(audioPath, language: language);
  }

  /// Time-aligned transcription for the lyrics panel.
  Future<List<TranscriptSegment>> transcribeSegments(String audioPath,
      {String language = 'ru'}) async {
    final raw = await impl.transcribeSegments(audioPath, language: language);
    if (raw.trim().isEmpty) return const [];
    final list = jsonDecode(raw);
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map)
          TranscriptSegment(
            (e['startMs'] as num?)?.toInt() ?? 0,
            (e['endMs'] as num?)?.toInt() ?? 0,
            (e['text'] as String?) ?? '',
          ),
    ];
  }

  void destroy() {
    impl.destroy();
  }

  final WhisperWebServiceImpl impl = WhisperWebServiceImpl();
}

/// One time-aligned chunk of recognised audio.
class TranscriptSegment {
  final int startMs;
  final int endMs;
  final String text;
  const TranscriptSegment(this.startMs, this.endMs, this.text);
}
