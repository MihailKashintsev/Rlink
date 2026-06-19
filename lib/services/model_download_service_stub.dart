import 'package:flutter/foundation.dart';

import 'whisper_model.dart';

/// Web-заглушка [ModelDownloadService]: на вебе модель кешируется в IndexedDB
/// силами whisper.cpp WASM, отдельная загрузка ggml-файла на диск не нужна.
class ModelDownloadService {
  ModelDownloadService._();
  static final ModelDownloadService instance = ModelDownloadService._();

  final ValueNotifier<double?> progress = ValueNotifier(null);
  final ValueNotifier<WhisperModelSize?> downloading = ValueNotifier(null);

  Future<bool> isDownloaded(WhisperModelSize size) async => false;

  Future<String?> resolvedPath(WhisperModelSize size) async => null;

  Future<int?> downloadedSize(WhisperModelSize size) async => null;

  Future<String> ensureDownloaded(WhisperModelSize size) async =>
      throw UnsupportedError('Загрузка моделей недоступна в веб-сборке');

  Future<void> delete(WhisperModelSize size) async {}
}
