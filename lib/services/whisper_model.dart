/// Размеры локальной модели Whisper (ggml) для расшифровки аудио.
///
/// `tiny` поставляется в комплекте приложения (assets/models/ggml-tiny.bin),
/// `base` и `small` скачиваются по запросу через [ModelDownloadService].
/// Платформенно-нейтральный файл (без dart:io) — импортируется и на вебе.
enum WhisperModelSize {
  tiny,
  base,
  small;

  /// Имя ggml-файла на диске и в репозитории whisper.cpp.
  String get fileName => 'ggml-$name.bin';

  String get displayName {
    switch (this) {
      case WhisperModelSize.tiny:
        return 'Tiny — быстрая';
      case WhisperModelSize.base:
        return 'Base — точнее';
      case WhisperModelSize.small:
        return 'Small — макс. точность';
    }
  }

  /// Ожидаемый размер файла в байтах (для UI и проверки полноты загрузки).
  int get approxBytes {
    switch (this) {
      case WhisperModelSize.tiny:
        return 77691713;
      case WhisperModelSize.base:
        return 147951465;
      case WhisperModelSize.small:
        return 487601967;
    }
  }

  /// Прямая ссылка на ggml-модель в репозитории whisper.cpp на Hugging Face.
  String get downloadUrl =>
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$fileName';

  /// tiny идёт в комплекте — её не нужно скачивать.
  bool get isBundled => this == WhisperModelSize.tiny;

  static WhisperModelSize fromIndex(int? i) {
    if (i == null || i < 0 || i >= WhisperModelSize.values.length) {
      return WhisperModelSize.tiny;
    }
    return WhisperModelSize.values[i];
  }
}
