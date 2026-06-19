import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'whisper_ffi.dart';
import 'model_download_service.dart';
import 'whisper_kit_apple.dart';

/// IO-specific code for LocalTranscriptionService (native platforms only).
///
/// Apple (iOS/macOS) → WhisperKit (on-device, built-in).
/// Android/Windows/Linux → whisper.cpp через FFI с выбранной ggml-моделью.
class LocalTranscriptionServiceIO {
  /// Путь к ggml-файлу по размеру (кешируем, чтобы не пересобирать).
  static final Map<WhisperModelSize, String> _cppModelPaths = {};

  /// Какой размер сейчас загружен в FFI — чтобы перезагрузить при смене.
  static WhisperModelSize? _loadedFfiSize;

  static bool get isApplePlatform => Platform.isIOS || Platform.isMacOS;

  static Future<String> resolveModelPath({
    WhisperModelSize size = WhisperModelSize.tiny,
  }) async {
    final cached = _cppModelPaths[size];
    if (cached != null && File(cached).existsSync()) return cached;

    final dir = await getApplicationDocumentsDirectory();
    final modelDir = p.join(dir.path, 'whisper_models');
    await Directory(modelDir).create(recursive: true);
    final modelPath = p.join(modelDir, size.fileName);

    if (!File(modelPath).existsSync()) {
      if (size.isBundled) {
        // tiny идёт в комплекте — распаковываем из assets при первом запуске.
        try {
          final data = await rootBundle.load('assets/models/${size.fileName}');
          await File(modelPath).writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            flush: true,
          );
        } catch (_) {
          // Падаем с явной ошибкой в ensureModel().
        }
      } else {
        // base/small скачиваются заранее через настройки.
        final downloaded =
            await ModelDownloadService.instance.resolvedPath(size);
        if (downloaded != null) {
          _cppModelPaths[size] = downloaded;
          return downloaded;
        }
      }
    }

    _cppModelPaths[size] = modelPath;
    return modelPath;
  }

  static Future<void> ensureModel({
    required bool isApple,
    WhisperModelSize size = WhisperModelSize.tiny,
  }) async {
    if (isApple) {
      await WhisperKitApple.instance
          .ensureModel(WhisperKitApple.variantForSize(size.name));
      return;
    }

    final modelPath = await resolveModelPath(size: size);
    if (!File(modelPath).existsSync()) {
      throw StateError(
        size.isBundled
            ? 'Локальная модель Whisper не установлена. '
                'Добавьте assets/models/${size.fileName}.'
            : 'Модель «${size.displayName}» не скачана. '
                'Скачайте её в Настройках → Расшифровка.',
      );
    }
    WhisperFfi.instance.load();
    if (!WhisperFfi.instance.isLoaded || _loadedFfiSize != size) {
      final result = WhisperFfi.instance.loadModel(modelPath);
      if (result != 0) {
        _loadedFfiSize = null;
        throw StateError(
            'Whisper model load failed: ${WhisperFfi.instance.lastError()}');
      }
      _loadedFfiSize = size;
    }
  }

  static Future<String> transcribeCpp(String audioPath, String language) async {
    if (!WhisperFfi.instance.isLoaded) {
      throw StateError('Whisper FFI not loaded');
    }
    final text = WhisperFfi.instance.transcribe(audioPath, language: language);
    if (text.trim().isEmpty) throw StateError('Речь не распознана');
    return text.trim();
  }

  static Future<String> transcribeApple(
      String audioPath, String language) async {
    return WhisperKitApple.instance.transcribe(audioPath, language);
  }
}
