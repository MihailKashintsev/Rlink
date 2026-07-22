import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

typedef _LoadNative = Int32 Function(Pointer<Utf8> modelPath);
typedef _LoadDart = int Function(Pointer<Utf8> modelPath);

typedef _TranscribeNative = Pointer<Utf8> Function(Pointer<Utf8> audioPath, Pointer<Utf8> language);
typedef _TranscribeDart = Pointer<Utf8> Function(Pointer<Utf8> audioPath, Pointer<Utf8> language);

typedef _FreeTextNative = Void Function(Pointer<Utf8> text);
typedef _FreeTextDart = void Function(Pointer<Utf8> text);

typedef _FreeModelNative = Void Function();
typedef _FreeModelDart = void Function();

typedef _LastErrorNative = Pointer<Utf8> Function();
typedef _LastErrorDart = Pointer<Utf8> Function();

class WhisperFfi {
  static WhisperFfi? _instance;
  DynamicLibrary? _lib;
  _LoadDart? _load;
  _TranscribeDart? _transcribe;
  _FreeTextDart? _freeText;
  _FreeModelDart? _freeModel;
  _LastErrorDart? _lastError;

  WhisperFfi._();

  static WhisperFfi get instance {
    _instance ??= WhisperFfi._();
    return _instance!;
  }

  bool get isLoaded => _lib != null;

  void load() {
    if (_lib != null) return;
    try {
      if (Platform.isWindows) {
        _lib = DynamicLibrary.open('whisper_bridge.dll');
      } else if (Platform.isAndroid) {
        _lib = DynamicLibrary.open('libwhisper_bridge.so');
      } else if (Platform.isLinux) {
        _lib = DynamicLibrary.open('libwhisper_bridge.so');
      } else {
        throw UnsupportedError('Unsupported platform for whisper FFI');
      }

      _load = _lib!.lookupFunction<_LoadNative, _LoadDart>('whisper_bridge_load');
      _transcribe = _lib!.lookupFunction<_TranscribeNative, _TranscribeDart>('whisper_bridge_transcribe');
      _freeText = _lib!.lookupFunction<_FreeTextNative, _FreeTextDart>('whisper_bridge_free_text');
      _freeModel = _lib!.lookupFunction<_FreeModelNative, _FreeModelDart>('whisper_bridge_free_model');
      _lastError = _lib!.lookupFunction<_LastErrorNative, _LastErrorDart>('whisper_bridge_last_error');
    } catch (e) {
      _lib = null;
      rethrow;
    }
  }

  int loadModel(String modelPath) {
    final fn = _load;
    if (fn == null) throw StateError('Whisper FFI not loaded');
    final pathPtr = modelPath.toNativeUtf8();
    try {
      return fn(pathPtr);
    } finally {
      calloc.free(pathPtr);
    }
  }

  String transcribe(String audioPath, {String language = 'ru'}) {
    final fn = _transcribe;
    if (fn == null) throw StateError('Whisper FFI not loaded');
    final audioPtr = audioPath.toNativeUtf8();
    final langPtr = language.toNativeUtf8();
    try {
      final resultPtr = fn(audioPtr, langPtr);
      if (resultPtr == nullptr) {
        throw StateError(lastError());
      }
      final text = resultPtr.toDartString();
      _freeText?.call(resultPtr);
      return text;
    } finally {
      calloc.free(audioPtr);
      calloc.free(langPtr);
    }
  }

  String lastError() {
    final fn = _lastError;
    if (fn == null) return 'FFI not loaded';
    final ptr = fn();
    if (ptr == nullptr) return 'Unknown error';
    return ptr.toDartString();
  }

  void freeModel() {
    _freeModel?.call();
  }

  void dispose() {
    freeModel();
    _lib = null;
    _load = null;
    _transcribe = null;
    _freeText = null;
    _freeModel = null;
    _lastError = null;
  }

  /// Runs the synchronous FFI transcription on a background isolate so the
  /// UI isolate stays responsive during long inference.
  Future<String> transcribeAsync(String audioPath, {String language = 'ru'}) =>
      Isolate.run(() => _transcribeInIsolate(audioPath, language));
}

// Top-level: Isolate.run needs a closure that captures only sendable values
// (Strings are). The native library is process-global — DynamicLibrary.open
// returns the already-mapped SO from cache with no disk I/O.
String _transcribeInIsolate(String audioPath, String language) {
  late final DynamicLibrary lib;
  if (Platform.isAndroid || Platform.isLinux) {
    lib = DynamicLibrary.open('libwhisper_bridge.so');
  } else if (Platform.isWindows) {
    lib = DynamicLibrary.open('whisper_bridge.dll');
  } else {
    throw UnsupportedError('whisper FFI not supported on this platform');
  }
  final transcribe = lib.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>(
    'whisper_bridge_transcribe',
  );
  final freeText = lib.lookupFunction<Void Function(Pointer<Utf8>),
      void Function(Pointer<Utf8>)>('whisper_bridge_free_text');
  final ap = audioPath.toNativeUtf8();
  final lp = language.toNativeUtf8();
  try {
    final r = transcribe(ap, lp);
    if (r == nullptr) return '';
    final text = r.toDartString();
    freeText(r);
    return text;
  } finally {
    calloc.free(ap);
    calloc.free(lp);
  }
}
