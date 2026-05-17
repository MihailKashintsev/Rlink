import 'package:flutter/foundation.dart';

import 'whisper_web_service.dart';
import 'huggingface_stt_service.dart';

// Conditional imports: use IO-specific code on native platforms, stub on web
import 'local_transcription_service_stub.dart'
    if (dart.library.io) 'local_transcription_service_io.dart';

/// Локальная (on-device) расшифровка аудио через Whisper.
///
/// iOS/macOS: cloud-first via Hugging Face; local WhisperKit dependency removed.
/// Android/Windows/Linux: whisper.cpp через FFI
/// Web: whisper.cpp через WASM (модель кешируется в IndexedDB)
class LocalTranscriptionService {
  LocalTranscriptionService._();
  static final LocalTranscriptionService instance =
      LocalTranscriptionService._();

  bool _modelReady = false;
  bool _loadingModel = false;
  bool preferCloud = true;

  /// Все платформы поддерживают локальную расшифровку.
  bool get isSupported => true;

  /// Web-платформа.
  bool get _isWeb => kIsWeb;

  /// Apple-платформа (только на native, через LocalTranscriptionServiceIO)
  bool get _isApplePlatform =>
      !kIsWeb && LocalTranscriptionServiceIO.isApplePlatform;

  /// Преобразует locale приложения в код языка для Whisper.
  /// Поддерживаемые языки Whisper: ru, en, es, de, fr, it, pt, nl, pl, tr, ja, ko, zh
  static String mapLocaleToWhisperLanguage(String appLocale) {
    if (appLocale == 'system') {
      // Для системного языка используем русский как дефолт
      return 'ru';
    }
    // Прямое маппинг для поддерживаемых языков
    final supported = {
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

  Future<void> _ensureModel() async {
    if (_modelReady) return;
    if (_loadingModel) {
      while (_loadingModel) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      if (_modelReady) return;
    }
    _loadingModel = true;
    try {
      if (_isWeb) {
        await WhisperWebService.instance.init();
      } else if (_isApplePlatform) {
        throw StateError(
          'Локальная Apple-расшифровка отключена: используется cloud STT.',
        );
      } else {
        // Desktop/Android: use LocalTranscriptionServiceIO for FFI
        await LocalTranscriptionServiceIO.ensureModel(isApple: false);
      }
      _modelReady = true;
    } catch (e) {
      throw StateError('Не удалось загрузить модель для расшифровки: $e');
    } finally {
      _loadingModel = false;
    }
  }

  Future<String> transcribeFile(String audioPath,
      {String language = 'ru'}) async {
    if (audioPath.isEmpty) {
      throw ArgumentError('Файл не найден: $audioPath');
    }
    Object? cloudError;
    if (preferCloud) {
      try {
        return await HuggingFaceSttService.instance.transcribeFile(
          audioPath,
          language: language,
        );
      } catch (e) {
        cloudError = e;
        debugPrint('[STT] Hugging Face failed, falling back locally: $e');
      }
    }

    try {
      await _ensureModel();

      if (_isWeb) {
        return _transcribeWeb(audioPath, language);
      } else if (_isApplePlatform) {
        return _transcribeApple(audioPath, language);
      } else {
        return _transcribeCpp(audioPath, language);
      }
    } catch (localError) {
      if (cloudError != null) {
        throw StateError(
          'Сетевая расшифровка недоступна ($cloudError), '
          'локальная модель тоже не запустилась ($localError)',
        );
      }
      rethrow;
    }
  }

  Future<String> _transcribeApple(String audioPath, String language) async {
    throw StateError(
      'Локальная Apple-расшифровка отключена: используется cloud STT.',
    );
  }

  Future<String> _transcribeCpp(String audioPath, String language) async {
    return LocalTranscriptionServiceIO.transcribeCpp(audioPath, language);
  }

  Future<String> _transcribeWeb(String audioPath, String language) async {
    final text = await WhisperWebService.instance
        .transcribe(audioPath, language: language);
    if (text.trim().isEmpty) throw StateError('Речь не распознана');
    return text.trim();
  }
}
