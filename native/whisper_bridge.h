#ifndef WHISPER_BRIDGE_H
#define WHISPER_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
#define WHISPER_EXPORT __declspec(dllexport)
#else
#define WHISPER_EXPORT __attribute__((visibility("default")))
#endif

/// Load a whisper model from file. Returns 0 on success.
WHISPER_EXPORT int whisper_bridge_load(const char* model_path);

/// Transcribe an audio file (16kHz mono WAV). Returns heap-allocated string (caller must free with whisper_bridge_free_text).
WHISPER_EXPORT char* whisper_bridge_transcribe(const char* audio_path, const char* language);

/// Free a string returned by whisper_bridge_transcribe.
WHISPER_EXPORT void whisper_bridge_free_text(char* text);

/// Free the loaded model.
WHISPER_EXPORT void whisper_bridge_free_model(void);

/// Get last error message.
WHISPER_EXPORT const char* whisper_bridge_last_error(void);

#ifdef __cplusplus
}
#endif

#endif // WHISPER_BRIDGE_H
