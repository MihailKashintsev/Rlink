/// Stub for WhisperFfi on platforms without dart:ffi (Web).
/// This is imported via conditional imports when dart.library.html is true.
class WhisperFfi {
  WhisperFfi._();
  static final WhisperFfi instance = WhisperFfi._();

  bool get isLoaded => false;

  void load() {
    throw UnsupportedError('Whisper FFI not available on web platform');
  }

  int loadModel(String modelPath) {
    throw UnsupportedError('Whisper FFI not available on web platform');
  }

  String transcribe(String audioPath, {String language = 'ru'}) {
    throw UnsupportedError('Whisper FFI not available on web platform');
  }

  String lastError() {
    return 'FFI not available on web';
  }

  void freeModel() {
    throw UnsupportedError('Whisper FFI not available on web platform');
  }

  void dispose() {
    throw UnsupportedError('Whisper FFI not available on web platform');
  }
}
