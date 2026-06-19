import 'package:flutter/foundation.dart';

import 'whisper_web_service.dart';
import 'huggingface_stt_service.dart';
import 'app_settings.dart';
import 'transcription_engine.dart';
import 'whisper_model.dart';
import '../utils/web_file_store.dart';

// Conditional imports: use IO-specific code on native platforms, stub on web
import 'local_transcription_service_stub.dart'
    if (dart.library.io) 'local_transcription_service_io.dart';

/// Расшифровка аудио/звонков. Движок и размер модели выбираются пользователем
/// в настройках ([AppSettings.transcriptionEngine] / [transcriptionModelSize]).
///
/// onDevice:
///   - iOS/macOS → WhisperKit (Apple, on-device, «встроенная»)
///   - Android/Windows/Linux → whisper.cpp через FFI
///   - Web → whisper.cpp через WASM (модель в IndexedDB)
/// cloud:
///   - Hugging Face STT (аудио уходит на сервер)
class LocalTranscriptionService {
  LocalTranscriptionService._();
  static final LocalTranscriptionService instance =
      LocalTranscriptionService._();

  bool _modelReady = false;
  bool _loadingModel = false;

  /// Размер модели, для которого выполнена инициализация (переинициализируем
  /// при смене в настройках).
  WhisperModelSize? _readySize;

  /// Все платформы поддерживают расшифровку (локально или через облако).
  bool get isSupported => true;

  bool get _isWeb => kIsWeb;

  bool get _isApplePlatform =>
      !kIsWeb && LocalTranscriptionServiceIO.isApplePlatform;

  TranscriptionEngine get _engine => AppSettings.instance.transcriptionEngine;
  WhisperModelSize get _modelSize => AppSettings.instance.transcriptionModelSize;

  /// Преобразует locale приложения в код языка для Whisper.
  /// Поддерживаемые: ru, en, es, de, fr, it, pt, nl, pl, tr, ja, ko, zh
  static String mapLocaleToWhisperLanguage(String appLocale) {
    if (appLocale == 'system') return 'ru';
    const supported = {
      'ru': 'ru',
      'en': 'en',
      'es': 'es',
      'de': 'de',
      'fr': 'fr',
      'it': 'it',
      'pt': 'pt',
      'nl': 'nl',
      'pl': 'pl',
      'tr': 'tr',
      'ja': 'ja',
      'ko': 'ko',
      'zh': 'zh',
    };
    return supported[appLocale] ?? 'ru';
  }

  Future<void> _ensureModel(WhisperModelSize size) async {
    if (_modelReady && _readySize == size) return;
    if (_loadingModel) {
      while (_loadingModel) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      if (_modelReady && _readySize == size) return;
    }
    _loadingModel = true;
    try {
      if (_isWeb) {
        // Web кеширует модель в IndexedDB силами WASM (tiny).
        await WhisperWebService.instance.init();
      } else if (_isApplePlatform) {
        await LocalTranscriptionServiceIO.ensureModel(isApple: true, size: size);
      } else {
        await LocalTranscriptionServiceIO.ensureModel(
            isApple: false, size: size);
      }
      _modelReady = true;
      _readySize = size;
    } catch (e) {
      _modelReady = false;
      throw StateError('Не удалось загрузить модель для расшифровки: $e');
    } finally {
      _loadingModel = false;
    }
  }

  Future<String> _transcribeOnDevice(
      String audioPath, String language, WhisperModelSize size) async {
    await _ensureModel(size);
    if (_isWeb) return _transcribeWeb(audioPath, language);
    if (_isApplePlatform) {
      return LocalTranscriptionServiceIO.transcribeApple(audioPath, language);
    }
    return LocalTranscriptionServiceIO.transcribeCpp(audioPath, language);
  }

  Future<String> transcribeFile(String audioPath,
      {String language = 'ru'}) async {
    if (audioPath.isEmpty) {
      throw ArgumentError('Файл не найден: $audioPath');
    }
    final engine = _engine;
    final size = _modelSize;

    if (engine == TranscriptionEngine.cloud) {
      // Облако выбрано явно: пробуем HF, при сбое (нет сети) — локально.
      try {
        return await HuggingFaceSttService.instance
            .transcribeFile(audioPath, language: language);
      } catch (cloudError) {
        debugPrint('[STT] Cloud failed, falling back on-device: $cloudError');
        try {
          return await _transcribeOnDevice(audioPath, language, size);
        } catch (localError) {
          throw StateError(
            'Облачная расшифровка недоступна ($cloudError), '
            'локальная тоже не запустилась ($localError)',
          );
        }
      }
    }

    // onDevice (по умолчанию). Приватность: при сбое НЕ уходим молча в облако —
    // пробрасываем ошибку (например «скачайте модель в настройках»), чтобы
    // аудио не утекло на сервер без ведома пользователя.
    return _transcribeOnDevice(audioPath, language, size);
  }

  Future<String> _transcribeWeb(String audioPath, String language) async {
    var path = audioPath;
    if (isWebStoredFile(path)) {
      path = await webStoredFileObjectUrl(
            path,
            mimeType: 'audio/webm',
          ) ??
          path;
    }
    final text =
        await WhisperWebService.instance.transcribe(path, language: language);
    if (text.trim().isEmpty) throw StateError('Речь не распознана');
    return text.trim();
  }
}
