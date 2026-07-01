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
#include <stdio.h>
#include <stdint.h>

static struct whisper_context* g_ctx = NULL;
static char g_last_error[512] = {0};

static void set_error(const char* msg) {
    strncpy(g_last_error, msg, sizeof(g_last_error) - 1);
    g_last_error[sizeof(g_last_error) - 1] = '\0';
}

// ── Minimal WAV (RIFF/PCM16) reader → 16 kHz mono float ─────────────────────
// whisper_full() wants 16 kHz mono f32 PCM, NOT a file path. The Dart side hands
// us a PCM16 WAV (decoded from the recorded m4a). Any rate / channel count is
// down-mixed + linearly resampled to 16 kHz mono here.
static uint32_t rd_u32(const unsigned char* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint16_t rd_u16(const unsigned char* p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static float* load_wav_16k_mono(const char* path, int* out_n) {
    *out_n = 0;
    FILE* f = fopen(path, "rb");
    if (!f) { set_error("Cannot open audio file"); return NULL; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size < 44) { fclose(f); set_error("Audio file too small"); return NULL; }
    unsigned char* buf = (unsigned char*)malloc((size_t)size);
    if (!buf) { fclose(f); set_error("OOM reading audio"); return NULL; }
    if (fread(buf, 1, (size_t)size, f) != (size_t)size) {
        fclose(f); free(buf); set_error("Short read on audio"); return NULL;
    }
    fclose(f);

    if (memcmp(buf, "RIFF", 4) != 0 || memcmp(buf + 8, "WAVE", 4) != 0) {
        free(buf); set_error("Not a WAV file"); return NULL;
    }

    uint16_t channels = 1, bits = 16;
    uint32_t rate = 16000;
    const unsigned char* data = NULL;
    uint32_t data_len = 0;

    size_t pos = 12;
    while (pos + 8 <= (size_t)size) {
        const unsigned char* ck = buf + pos;
        uint32_t clen = rd_u32(ck + 4);
        if (memcmp(ck, "fmt ", 4) == 0 && clen >= 16) {
            channels = rd_u16(ck + 10);
            rate = rd_u32(ck + 12);
            bits = rd_u16(ck + 22);
        } else if (memcmp(ck, "data", 4) == 0) {
            data = ck + 8;
            data_len = clen;
            if (pos + 8 + (size_t)clen > (size_t)size) {
                data_len = (uint32_t)((size_t)size - pos - 8);
            }
            break;
        }
        pos += 8 + clen + (clen & 1);
    }
    if (!data || data_len == 0 || bits != 16 || channels == 0) {
        free(buf); set_error("Unsupported WAV (need PCM16)"); return NULL;
    }

    uint32_t frames = data_len / (2u * channels);
    if (frames == 0) { free(buf); set_error("Empty audio"); return NULL; }
    float* mono = (float*)malloc(sizeof(float) * frames);
    if (!mono) { free(buf); set_error("OOM mono"); return NULL; }
    const int16_t* s = (const int16_t*)data;
    for (uint32_t i = 0; i < frames; i++) {
        int acc = 0;
        for (uint16_t c = 0; c < channels; c++) acc += s[i * channels + c];
        mono[i] = (float)acc / ((float)channels * 32768.0f);
    }
    free(buf);

    if (rate == 16000) { *out_n = (int)frames; return mono; }

    double ratio = 16000.0 / (double)rate;
    uint32_t on = (uint32_t)((double)frames * ratio);
    if (on == 0) { free(mono); set_error("Resample produced no samples"); return NULL; }
    float* out = (float*)malloc(sizeof(float) * on);
    if (!out) { free(mono); set_error("OOM resample"); return NULL; }
    for (uint32_t i = 0; i < on; i++) {
        double src = (double)i / ratio;
        uint32_t i0 = (uint32_t)src;
        double frac = src - (double)i0;
        float a = mono[i0 < frames ? i0 : frames - 1];
        float b = mono[(i0 + 1) < frames ? (i0 + 1) : frames - 1];
        out[i] = a + (float)((double)(b - a) * frac);
    }
    free(mono);
    *out_n = (int)on;
    return out;
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

    int n_samples = 0;
    float* pcm = load_wav_16k_mono(audio_path, &n_samples);
    if (!pcm || n_samples <= 0) {
        if (pcm) free(pcm);
        return NULL; // error already set
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

    int rc = whisper_full_parallel(g_ctx, params, pcm, n_samples, 1);
    free(pcm);
    if (rc != 0) {
        set_error("Transcription failed");
        return NULL;
    }

    const int n_segments = whisper_full_n_segments(g_ctx);
    if (n_segments <= 0) {
        set_error("No speech detected");
        return NULL;
    }

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
