import 'dart:async';

/// Stub implementation for non-web platforms (macOS, iOS, Android, etc.)
class WhisperWebServiceImpl {
  bool _ready = false;
  bool _loading = false;
  String? _lastError;

  bool get isReady => _ready;

  String? get lastError => _lastError;

  Future<void> init({void Function(int loaded, int total)? onProgress}) async {
    _lastError = 'Whisper is only supported on web platform';
    throw StateError(_lastError!);
  }

  Future<String> transcribe(String audioPath, {String language = 'ru'}) async {
    throw StateError('Whisper is only supported on web platform');
  }

  Future<String> transcribeSegments(String audioPath,
      {String language = 'ru'}) async {
    throw StateError('Whisper is only supported on web platform');
  }

  void destroy() {
    _ready = false;
    _lastError = null;
  }
}
