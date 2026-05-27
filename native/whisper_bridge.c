#include "whisper_bridge.h"
#ifdef RLINK_NO_WHISPER
#include <string.h>
#include <stddef.h>

static char g_last_error[512] = {0};

static void set_error(const char* msg) {
    strncpy(g_last_error, msg, sizeof(g_last_error) - 1);
    g_last_error[sizeof(g_last_error) - 1] = '\0';
}

int whisper_bridge_load(const char* model_path) {
    (void)model_path;
    set_error("whisper.cpp is not bundled in native/whisper.cpp");
    return -1;
}

char* whisper_bridge_transcribe(const char* audio_path, const char* language) {
    (void)audio_path;
    (void)language;
    set_error("whisper.cpp is not bundled in native/whisper.cpp");
    return NULL;
}

void whisper_bridge_free_text(char* text) {
    (void)text;
}

void whisper_bridge_free_model(void) {}

const char* whisper_bridge_last_error(void) {
    return g_last_error;
}

#else
#include "whisper.h"
#include <string.h>
#include <stdlib.h>

static struct whisper_context* g_ctx = NULL;
static char g_last_error[512] = {0};

static void set_error(const char* msg) {
    strncpy(g_last_error, msg, sizeof(g_last_error) - 1);
    g_last_error[sizeof(g_last_error) - 1] = '\0';
}

int whisper_bridge_load(const char* model_path) {
    if (g_ctx) {
        whisper_free(g_ctx);
        g_ctx = NULL;
    }
    struct whisper_context_params params = whisper_context_default_params();
    g_ctx = whisper_init_from_file_with_params(model_path, params);
    if (!g_ctx) {
        set_error("Failed to load whisper model");
        return -1;
    }
    return 0;
}

char* whisper_bridge_transcribe(const char* audio_path, const char* language) {
    if (!g_ctx) {
        set_error("Model not loaded");
        return NULL;
    }

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_realtime = false;
    params.print_progress = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = false;
    params.language = language ? language : "ru";
    params.n_threads = 4;
    params.offset_ms = 0;
    params.no_context = true;
    params.single_segment = false;
    params.speed_up = false;
    params.no_timestamps = true;

    if (whisper_full_parallel(g_ctx, params, audio_path, 4) != 0) {
        set_error("Transcription failed");
        return NULL;
    }

    const int n_segments = whisper_full_n_segments(g_ctx);
    if (n_segments <= 0) {
        set_error("No speech detected");
        return NULL;
    }

    // Estimate total length
    size_t total_len = 0;
    for (int i = 0; i < n_segments; i++) {
        const char* seg_text = whisper_full_get_segment_text(g_ctx, i);
        if (seg_text) total_len += strlen(seg_text) + 2;
    }

    char* result = (char*)malloc(total_len + 1);
    if (!result) {
        set_error("Memory allocation failed");
        return NULL;
    }
    result[0] = '\0';

    for (int i = 0; i < n_segments; i++) {
        const char* seg_text = whisper_full_get_segment_text(g_ctx, i);
        if (seg_text && seg_text[0]) {
            if (i > 0) strcat(result, " ");
            strcat(result, seg_text);
        }
    }

    return result;
}

void whisper_bridge_free_text(char* text) {
    if (text) free(text);
}

void whisper_bridge_free_model(void) {
    if (g_ctx) {
        whisper_free(g_ctx);
        g_ctx = NULL;
    }
}

const char* whisper_bridge_last_error(void) {
    return g_last_error;
}
#endif
