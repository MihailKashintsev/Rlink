/// Размеры локальной модели Whisper (ggml) для расшифровки аудио.
///
/// Начиная с 1.0.0 ни одна модель не входит в комплект приложения — все
/// (`tiny`/`base`/`small`) скачиваются по запросу через [ModelDownloadService]
/// (при первой настройке или в Настройках → Расшифровка). Это уменьшает размер
/// установочного пакета примерно на 74 МБ.
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

  /// Раньше tiny входила в комплект; теперь все модели скачиваются по запросу,
  /// поэтому bundled-моделей больше нет. Оставлено для обратной совместимости
  /// вызовов, которые различали встроенную и скачиваемую модель.
  bool get isBundled => false;

  static WhisperModelSize fromIndex(int? i) {
    if (i == null || i < 0 || i >= WhisperModelSize.values.length) {
      return WhisperModelSize.tiny;
    }
    return WhisperModelSize.values[i];
  }
}
