import 'dart:typed_data';

import 'package:dio/dio.dart';

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
    throw ArgumentError('Файл недоступен для сетевой расшифровки: $audioPath');
  }
  final response = await dio.get<List<int>>(
    audioPath,
    options: Options(responseType: ResponseType.bytes),
  );
  final data = response.data;
  if (data == null || data.isEmpty) {
    throw StateError('Не удалось прочитать аудио');
  }
  return Uint8List.fromList(data);
}
