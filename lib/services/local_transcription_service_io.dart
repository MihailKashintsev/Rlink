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

    // Начиная с 1.0.0 модели не входят в комплект — они скачиваются по запросу
    // (в первой настройке или в Настройках → Расшифровка) и лежат в
    // <documents>/whisper_models/. Если уже скачано — возвращаем реальный путь.
    final downloaded = await ModelDownloadService.instance.resolvedPath(size);
    if (downloaded != null) {
      _cppModelPaths[size] = downloaded;
      return downloaded;
    }

    // Ещё не скачано — вернём целевой (несуществующий) путь, чтобы ensureModel
    // выбросил понятную ошибку с подсказкой скачать модель.
    final dir = await getApplicationDocumentsDirectory();
    final modelDir = p.join(dir.path, 'whisper_models');
    await Directory(modelDir).create(recursive: true);
    return p.join(modelDir, size.fileName);
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
        'Модель «${size.displayName}» ещё не скачана. '
        'Скачайте её в первой настройке или в Настройках → Расшифровка.',
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

  static const _audioChannel = MethodChannel('com.rendergames.rlink/audio');

  static Future<String> transcribeCpp(String audioPath, String language) async {
    if (!WhisperFfi.instance.isLoaded) {
      throw StateError('Whisper FFI not loaded');
    }
    // whisper.cpp reads a PCM16 WAV; the app records m4a/aac. On Android decode
    // it to WAV first (the native bridge down-mixes + resamples to 16 kHz mono).
    var wavPath = audioPath;
    if (Platform.isAndroid && !audioPath.toLowerCase().endsWith('.wav')) {
      final dst = '$audioPath.whisper.wav';
      try {
        final r = await _audioChannel.invokeMethod<String>(
            'toWav', {'src': audioPath, 'dst': dst});
        if (r != null && File(r).existsSync()) wavPath = r;
      } catch (e) {
        throw StateError('Не удалось декодировать аудио для расшифровки: $e');
      }
    }
    final text =
        await WhisperFfi.instance.transcribeAsync(wavPath, language: language);
    if (text.trim().isEmpty) throw StateError('Речь не распознана');
    return text.trim();
  }

  static Future<String> transcribeApple(
      String audioPath, String language) async {
    return WhisperKitApple.instance.transcribe(audioPath, language);
  }
}
