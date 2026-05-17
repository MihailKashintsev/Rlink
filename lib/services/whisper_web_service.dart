// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'whisper_web_service_stub.dart'
    if (dart.library.js) 'whisper_web_service_web.dart';

/// Web-реализация расшифровки через whisper.cpp WASM.
/// Использует JS-объект window.rlinkWhisper (whisper_web.js).
class WhisperWebService {
  WhisperWebService._();
  static final WhisperWebService instance = WhisperWebService._();

  bool get isSupported => kIsWeb;

  bool get isReady => impl.isReady;

  String? get lastError => impl.lastError;

  Future<void> init({void Function(int loaded, int total)? onProgress}) async {
    await impl.init(onProgress: onProgress);
  }

  Future<String> transcribe(String audioPath, {String language = 'ru'}) async {
    return impl.transcribe(audioPath, language: language);
  }

  void destroy() {
    impl.destroy();
  }

  final WhisperWebServiceImpl impl = WhisperWebServiceImpl();
}
