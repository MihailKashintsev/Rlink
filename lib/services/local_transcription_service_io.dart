import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'whisper_ffi.dart';

/// IO-specific code for LocalTranscriptionService (native platforms only).
class LocalTranscriptionServiceIO {
  static String? _cppModelPath;

  static bool get isApplePlatform => Platform.isIOS || Platform.isMacOS;

  static Future<String> resolveModelPath() async {
    if (_cppModelPath != null) return _cppModelPath!;
    final dir = await getApplicationDocumentsDirectory();
    final modelDir = p.join(dir.path, 'whisper_models');
    await Directory(modelDir).create(recursive: true);
    final modelPath = p.join(modelDir, 'ggml-tiny.bin');
    _cppModelPath = modelPath;
    return modelPath;
  }

  static Future<void> ensureModel({required bool isApple}) async {
    if (isApple) {
      // WhisperKit handled in main file
      return;
    }
    final modelPath = await resolveModelPath();
    if (!File(modelPath).existsSync()) {
      throw StateError(
        'Локальная модель Whisper не установлена. '
        'Cloud STT используется первым; для офлайн-режима скачайте модель через scripts/download_whisper_model.sh.',
      );
    }
    WhisperFfi.instance.load();
    final result = WhisperFfi.instance.loadModel(modelPath);
    if (result != 0) {
      throw StateError(
          'Whisper model load failed: ${WhisperFfi.instance.lastError()}');
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
}
