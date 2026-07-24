// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:js' as js;

/// Web implementation using whisper.cpp WASM.
/// Uses JS object window.rlinkWhisper (whisper_web.js).
class WhisperWebServiceImpl {
  bool _ready = false;
  bool _loading = false;
  String? _lastError;

  bool get isReady => _ready;

  String? get lastError => _lastError;

  Future<void> init({void Function(int loaded, int total)? onProgress}) async {
    if (_ready) return;
    if (_loading) {
      while (_loading) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (_ready) return;
      if (_lastError != null) throw StateError(_lastError!);
      return;
    }
    _loading = true;
    _lastError = null;
    try {
      final whisper = _jsWhisper;
      if (whisper == null) throw StateError('rlinkWhisper not found in window');

      final supported = whisper.callMethod('isSupported');
      if (supported != true) {
        throw StateError(
            'WebAssembly или IndexedDB не поддерживаются браузером');
      }

      if (onProgress != null) {
        whisper.callMethod('init', [
          (int loaded, int total) {
            onProgress(loaded, total);
          },
        ]);
      } else {
        whisper.callMethod('init', []);
      }
      await _waitForReady();

      _ready = true;
    } catch (e) {
      _lastError = e.toString();
      rethrow;
    } finally {
      _loading = false;
    }
  }

  Future<void> _waitForReady() async {
    final whisper = _jsWhisper;
    if (whisper == null) return;
    for (var i = 0; i < 300; i++) {
      final ready = whisper.callMethod('isReady');
      if (ready == true) return;
      final err = whisper.callMethod('lastError');
      if (err != null && err.toString().isNotEmpty) {
        throw StateError(err.toString());
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError('Whisper init timed out');
  }

  Future<String> transcribeSegments(String audioPath,
          {String language = 'ru'}) =>
      _call('transcribeSegments', audioPath, language);

  Future<String> transcribe(String audioPath, {String language = 'ru'}) =>
      _call('transcribe', audioPath, language);

  Future<String> _call(String method, String audioPath, String language) async {
    if (!_ready)
      throw StateError('Whisper not initialized. Call init() first.');

    final whisper = _jsWhisper;
    if (whisper == null) throw StateError('rlinkWhisper not found');

    final completer = Completer<String>();
    try {
      final result = whisper.callMethod(method, [audioPath, language]);
      if (result is String) return result;

      if (result != null) {
        final jsPromise = result;
        try {
          jsPromise.callMethod('then', [
            (dynamic text) {
              if (!completer.isCompleted)
                completer.complete(text?.toString() ?? '');
            },
          ]);
          jsPromise.callMethod('catch', [
            (dynamic err) {
              if (!completer.isCompleted) {
                completer
                    .completeError(err?.toString() ?? 'Transcription failed');
              }
            },
          ]);
        } catch (_) {
          return result.toString();
        }
        return completer.future.timeout(
          const Duration(minutes: 5),
          onTimeout: () => throw TimeoutException('Transcription timed out'),
        );
      }

      final err = whisper.callMethod('lastError');
      throw StateError(err?.toString() ?? 'Transcription failed');
    } catch (e) {
      if (e is StateError) rethrow;
      throw StateError('Transcription error: $e');
    }
  }

  void destroy() {
    final whisper = _jsWhisper;
    if (whisper != null) {
      whisper.callMethod('destroy');
    }
    _ready = false;
    _lastError = null;
  }

  dynamic get _jsWhisper {
    try {
      return js.context['rlinkWhisper'];
    } catch (_) {
      return null;
    }
  }
}
