// Публичная точка входа для загрузки моделей Whisper.
//
// Реэкспортирует native-реализацию (dart:io) или web-заглушку, а также
// перечисление WhisperModelSize, чтобы потребителям хватало одного импорта.
export 'whisper_model.dart';
export 'model_download_service_stub.dart'
    if (dart.library.io) 'model_download_service_io.dart';
