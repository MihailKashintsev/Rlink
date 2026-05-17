import 'package:dio/dio.dart';

import 'huggingface_audio_loader_stub.dart'
    if (dart.library.io) 'huggingface_audio_loader_io.dart';

/// Бесплатная расшифровка аудио через Hugging Face Inference API.
/// Не требует собственного сервера и не жрёт место моделями на устройстве.
///
/// Работает без API-токена (rate-limited). Для production вставьте
/// токен в [apiToken] — получить бесплатно на https://huggingface.co/settings/tokens
class HuggingFaceSttService {
  HuggingFaceSttService._();
  static final HuggingFaceSttService instance = HuggingFaceSttService._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 60),
  ));

  static const _model = 'openai/whisper-large-v3-turbo';
  static const _endpoint =
      'https://api-inference.huggingface.co/models/$_model';

  /// Распознаёт аудиофайл и возвращает текст.
  /// [language] передаётся как query-параметр (некоторые endpoint HF игнорируют,
  /// но для совместимости оставлен).
  Future<String> transcribeFile(
    String audioPath, {
    String language = 'ru',
    String? apiToken,
  }) async {
    final bytes = await loadAudioBytesForHuggingFace(audioPath, _dio);

    final headers = <String, String>{
      'Content-Type': 'application/octet-stream',
      if (apiToken != null && apiToken.isNotEmpty)
        'Authorization': 'Bearer $apiToken',
    };

    try {
      final response = await _dio.post<dynamic>(
        '$_endpoint?task=transcribe&language=$language',
        data: Stream.fromIterable([bytes]),
        options: Options(
          headers: headers,
          responseType: ResponseType.json,
        ),
      );

      if (response.statusCode == 503) {
        throw StateError(
            'Модель загружается на сервере Hugging Face. Попробуйте через минуту.');
      }

      final data = response.data;
      if (data is Map<String, dynamic>) {
        final text = (data['text'] as String?)?.trim();
        if (text != null && text.isNotEmpty) return text;

        // Некоторые версии endpoint возвращают chunks
        final chunks = data['chunks'] as List<dynamic>?;
        if (chunks != null && chunks.isNotEmpty) {
          final buf = StringBuffer();
          for (final c in chunks) {
            if (c is Map) {
              final t = (c['text'] as String?)?.trim();
              if (t != null && t.isNotEmpty) {
                if (buf.isNotEmpty) buf.write(' ');
                buf.write(t);
              }
            }
          }
          if (buf.isNotEmpty) return buf.toString();
        }
      }
      throw StateError('Речь не распознана: неожиданный ответ сервера');
    } on DioException catch (e) {
      if (e.response?.statusCode == 503) {
        throw StateError(
            'Модель загружается на сервере Hugging Face. Попробуйте через минуту.');
      }
      final body = e.response?.data;
      if (body is Map && body['error'] != null) {
        throw StateError('Ошибка API: ${body['error']}');
      }
      throw StateError('Ошибка сети: ${e.message}');
    } catch (e) {
      throw StateError('Ошибка распознавания: $e');
    }
  }
}
