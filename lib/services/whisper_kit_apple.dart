import 'package:flutter_whisper_kit/flutter_whisper_kit.dart';

/// Тонкая обёртка над WhisperKit (Apple Neural Engine) — on-device STT для
/// iOS/macOS. Изолирует зависимость `flutter_whisper_kit`; вызывается только
/// когда `Platform.isIOS || Platform.isMacOS` (см. [LocalTranscriptionServiceIO]).
class WhisperKitApple {
  WhisperKitApple._();
  static final WhisperKitApple instance = WhisperKitApple._();

  final FlutterWhisperKit _whisper = FlutterWhisperKit();
  bool _loaded = false;
  String? _loadedVariant;

  /// Вариант модели WhisperKit для выбранного размера ggml-модели.
  static String variantForSize(String sizeName) {
    switch (sizeName) {
      case 'small':
        return 'small';
      case 'base':
        return 'base';
      case 'tiny':
      default:
        // tiny заметно хуже распознаёт русский — поднимаем минимум до base.
        return 'base';
    }
  }

  Future<void> ensureModel(String variant) async {
    if (_loaded && _loadedVariant == variant) return;
    final loaded = await _whisper.loadModel(variant);
    if (loaded == null || loaded.isEmpty) {
      throw StateError('WhisperKit: не удалось загрузить модель ($variant)');
    }
    _loaded = true;
    _loadedVariant = variant;
  }

  Future<String> transcribe(String audioPath, String language) async {
    // Явная JSON-сборка: только `task: transcribe` (не translate — иначе
    // выход на английском).
    final decode = DecodingOptions.fromJson(<String, dynamic>{
      'verbose': false,
      'task': 'transcribe',
      'language': language,
      'detectLanguage': false,
      'temperature': 0.0,
      'temperatureIncrementOnFallback': 0.2,
      'temperatureFallbackCount': 5,
      'sampleLength': 224,
      'topK': 5,
      'usePrefillPrompt': false,
      'usePrefillCache': false,
      'skipSpecialTokens': true,
      'withoutTimestamps': true,
      'wordTimestamps': false,
      'clipTimestamps': <double>[0.0],
      'concurrentWorkerCount': 4,
      'chunkingStrategy': 'vad',
    });
    final result = await _whisper.transcribeFromFile(audioPath, options: decode);
    final text = (result?.text ?? '').trim();
    if (text.isEmpty) throw StateError('Речь не распознана');
    return text;
  }
}
