import 'dart:typed_data';

import 'package:dio/dio.dart';
import '../l10n/app_l10n.dart';

Future<Uint8List> loadAudioBytesForHuggingFace(
  String audioPath,
  Dio dio,
) async {
  final uri = Uri.tryParse(audioPath);
  if (uri == null ||
      !(uri.scheme == 'http' ||
          uri.scheme == 'https' ||
          uri.scheme == 'blob' ||
          uri.scheme == 'data')) {
    throw ArgumentError(AppL10n.f('Файл недоступен для сетевой расшифровки: {0}', [audioPath]));
  }
  final response = await dio.get<List<int>>(
    audioPath,
    options: Options(responseType: ResponseType.bytes),
  );
  final data = response.data;
  if (data == null || data.isEmpty) {
    throw StateError(AppL10n.t('Не удалось прочитать аудио'));
  }
  return Uint8List.fromList(data);
}
