import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'whisper_model.dart';

/// Скачивание и хранение ggml-моделей Whisper (native-платформы).
///
/// Модели лежат в `<documents>/whisper_models/ggml-<size>.bin` — туда же
/// [LocalTranscriptionServiceIO] распаковывает встроенную tiny-модель, поэтому
/// пути совпадают.
class ModelDownloadService {
  ModelDownloadService._();
  static final ModelDownloadService instance = ModelDownloadService._();

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 30),
  ));

  /// Прогресс активной загрузки (0..1); null — загрузка не идёт.
  final ValueNotifier<double?> progress = ValueNotifier(null);

  /// Какая модель сейчас качается (для UI); null — никакая.
  final ValueNotifier<WhisperModelSize?> downloading = ValueNotifier(null);

  Future<Directory> _modelDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(dir.path, 'whisper_models'));
    await d.create(recursive: true);
    return d;
  }

  Future<String> _modelPath(WhisperModelSize size) async {
    final d = await _modelDir();
    return p.join(d.path, size.fileName);
  }

  /// Полноценный (не обрезанный) файл модели уже на диске?
  Future<bool> isDownloaded(WhisperModelSize size) async {
    final f = File(await _modelPath(size));
    if (!f.existsSync()) return false;
    final len = await f.length();
    // Любая ggml-модель — десятки/сотни МБ; так отсекаем обрезанные файлы.
    return len > 1024 * 1024;
  }

  Future<String?> resolvedPath(WhisperModelSize size) async {
    return (await isDownloaded(size)) ? _modelPath(size) : null;
  }

  Future<int?> downloadedSize(WhisperModelSize size) async {
    final f = File(await _modelPath(size));
    if (!f.existsSync()) return null;
    return f.length();
  }

  /// Гарантирует, что модель скачана; возвращает путь к файлу.
  /// Качает в `*.part` и переименовывает по завершении (атомарность).
  Future<String> ensureDownloaded(WhisperModelSize size) async {
    final path = await _modelPath(size);
    if (await isDownloaded(size)) return path;

    final tmp = '$path.part';
    final tmpFile = File(tmp);
    downloading.value = size;
    progress.value = 0.0;
    try {
      if (tmpFile.existsSync()) await tmpFile.delete();
      await _dio.download(
        size.downloadUrl,
        tmp,
        onReceiveProgress: (r, t) {
          if (t > 0) progress.value = r / t;
        },
      );
      final len = await tmpFile.length();
      if (len < 1024 * 1024) {
        if (tmpFile.existsSync()) await tmpFile.delete();
        throw StateError('Загрузка повреждена ($len Б)');
      }
      await tmpFile.rename(path);
      progress.value = 1.0;
      return path;
    } on DioException catch (e) {
      try {
        if (tmpFile.existsSync()) await tmpFile.delete();
      } catch (_) {}
      throw StateError('Не удалось скачать модель: ${e.message ?? e.type.name}');
    } finally {
      downloading.value = null;
      progress.value = null;
    }
  }

  /// Удаляет скачанную модель. tiny не трогаем — она встроена.
  Future<void> delete(WhisperModelSize size) async {
    if (size.isBundled) return;
    final f = File(await _modelPath(size));
    if (f.existsSync()) await f.delete();
  }
}
