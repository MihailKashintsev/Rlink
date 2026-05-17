import 'whisper_web_service.dart';

/// Stub for LocalTranscriptionService on web (no dart:io, no FFI).
/// This file is imported via conditional imports when dart.library.io is false.
class LocalTranscriptionServiceIO {
  static bool get isApplePlatform => false;

  static Future<void> ensureModel({required bool isApple}) async {
    await WhisperWebService.instance.init();
  }

  static Future<String> transcribeCpp(String audioPath, String language) async {
    throw UnsupportedError('Not available on web - use _transcribeWeb instead');
  }
}
