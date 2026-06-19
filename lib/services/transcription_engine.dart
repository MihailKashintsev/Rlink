/// Движок расшифровки аудио/звонков, выбираемый пользователем в настройках.
///
/// Платформенно-нейтральный файл (без dart:io) — импортируется и на вебе.
enum TranscriptionEngine {
  /// Локально на устройстве: WhisperKit на Apple, whisper.cpp (FFI) на
  /// Android/desktop, whisper.cpp (WASM) на вебе. Приватно и оффлайн.
  onDevice,

  /// Облачный STT (Hugging Face). Аудио уходит на внешний сервер.
  cloud;

  String get displayName {
    switch (this) {
      case TranscriptionEngine.onDevice:
        return 'На устройстве (локально)';
      case TranscriptionEngine.cloud:
        return 'Облако (Hugging Face)';
    }
  }

  static TranscriptionEngine fromIndex(int? i) {
    if (i == null || i < 0 || i >= TranscriptionEngine.values.length) {
      return TranscriptionEngine.onDevice;
    }
    return TranscriptionEngine.values[i];
  }
}
