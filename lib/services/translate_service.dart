import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'relay_service.dart';

/// Перевод выделенного текста. На web браузер блокирует прямой запрос к Google
/// (CORS), поэтому идём через relay-прокси `/translate` (сервер сам ходит в
/// Google Translate gtx-эндпоинт). На нативе можно и напрямую, но relay-путь
/// работает везде одинаково.
class TranslateService {
  TranslateService._();
  static final TranslateService instance = TranslateService._();

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 12),
  ));

  String _httpBase() {
    final url = RelayService.instance.serverUrl ?? RelayService.defaultServerUrl;
    if (url.startsWith('wss://')) return url.replaceFirst('wss://', 'https://');
    if (url.startsWith('ws://')) return url.replaceFirst('ws://', 'http://');
    return url;
  }

  /// Переводит [text] на [targetLang] (auto-детект источника). Возвращает
  /// перевод или null при ошибке.
  Future<String?> translate(String text, {required String targetLang}) async {
    final q = text.trim();
    if (q.isEmpty) return null;

    // 1) Relay-прокси (единственный надёжный путь на web).
    final base = _httpBase();
    if (base.isNotEmpty) {
      try {
        final resp = await _dio.get<dynamic>(
          '$base/translate',
          queryParameters: {'tl': targetLang, 'q': q},
        );
        final data = resp.data;
        if (data is Map && data['ok'] == true) {
          final t = (data['text'] as String?)?.trim();
          if (t != null && t.isNotEmpty) return t;
        }
      } catch (e) {
        debugPrint('[RLINK][Translate] relay proxy failed: $e');
      }
    }

    // 2) Прямой запрос к Google (работает на нативе; на web обычно блокируется
    //    CORS, но пробуем как запасной вариант).
    try {
      final resp = await _dio.get<dynamic>(
        'https://translate.googleapis.com/translate_a/single',
        queryParameters: {
          'client': 'gtx',
          'sl': 'auto',
          'tl': targetLang,
          'dt': 't',
          'q': q,
        },
      );
      final data = resp.data;
      if (data is List && data.isNotEmpty && data[0] is List) {
        final sb = StringBuffer();
        for (final seg in (data[0] as List)) {
          if (seg is List && seg.isNotEmpty && seg[0] is String) {
            sb.write(seg[0] as String);
          }
        }
        final out = sb.toString().trim();
        if (out.isNotEmpty) return out;
      }
    } catch (e) {
      debugPrint('[RLINK][Translate] direct failed: $e');
    }
    return null;
  }
}
