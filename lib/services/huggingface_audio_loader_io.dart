import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

Future<Uint8List> loadAudioBytesForHuggingFace(
  String audioPath,
  Dio dio,
) async {
  final file = File(audioPath);
  if (await file.exists()) {
    return file.readAsBytes();
  }
  final uri = Uri.tryParse(audioPath);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    final response = await dio.get<List<int>>(
      audioPath,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = response.data;
    if (data != null && data.isNotEmpty) return Uint8List.fromList(data);
  }
  throw ArgumentError('Файл не найден: $audioPath');
}
