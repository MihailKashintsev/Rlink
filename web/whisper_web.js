// whisper_web.js — Whisper transcription for Rlink Web via transformers.js
//
// Real in-browser speech-to-text using Hugging Face transformers.js
// (@huggingface/transformers). It downloads an ONNX Whisper model once,
// caches it in the browser Cache API, decodes + resamples audio to 16 kHz
// itself, and runs inference on the WASM backend (works in Safari too).
//
// The public API on window.rlinkWhisper exposes isSupported/isReady/lastError
// as METHODS (functions) — the Dart bridge (whisper_web_service_web.dart)
// calls them via callMethod(), so they must be callable, not getters.

(function () {
  'use strict';

  // ESM build of transformers.js, loaded lazily via dynamic import on first use.
  const TRANSFORMERS_URL =
    'https://cdn.jsdelivr.net/npm/@huggingface/transformers@3';
  // Multilingual tiny model (supports Russian). ONNX, cached in the browser.
  const MODEL_ID = 'Xenova/whisper-tiny';

  let _asr = null;
  let _ready = false;
  let _loading = false;
  let _lastError = '';

  window.rlinkWhisper = {
    isSupported() {
      return (
        typeof WebAssembly !== 'undefined' && typeof fetch !== 'undefined'
      );
    },

    isReady() {
      return _ready;
    },

    lastError() {
      return _lastError;
    },

    /// Download + initialize the model. onProgress(loaded, total) is called
    /// during the one-time model download.
    async init(onProgress) {
      if (_ready) return;
      if (_loading) {
        while (_loading) await new Promise((r) => setTimeout(r, 100));
        if (_ready) return;
        if (_lastError) throw new Error(_lastError);
        return;
      }
      _loading = true;
      _lastError = '';
      try {
        const mod = await import(TRANSFORMERS_URL);
        const { pipeline, env } = mod;
        // Always fetch models from the HF hub (no local model files bundled).
        env.allowLocalModels = false;
        _asr = await pipeline('automatic-speech-recognition', MODEL_ID, {
          progress_callback: (p) => {
            try {
              if (
                onProgress &&
                p &&
                p.status === 'progress' &&
                typeof p.loaded === 'number' &&
                typeof p.total === 'number'
              ) {
                onProgress(p.loaded, p.total);
              }
            } catch (_) {}
          },
        });
        _ready = true;
        console.log('[whisper-web] transformers.js ASR ready (' + MODEL_ID + ')');
      } catch (e) {
        _lastError = (e && e.message) ? e.message : String(e);
        console.error('[whisper-web] init failed:', _lastError);
        throw e;
      } finally {
        _loading = false;
      }
    },

    /// Transcribe audio at a (blob:) URL. Returns recognized text.
    /// transformers.js fetches the URL, decodes it via the Web Audio API and
    /// resamples to 16 kHz internally.
    async transcribe(audioPath, language) {
      if (!_ready || !_asr) {
        throw new Error('Whisper not initialized. Call init() first.');
      }
      const opts = {
        task: 'transcribe',
        chunk_length_s: 30,
        stride_length_s: 5,
        return_timestamps: false,
      };
      const lang = (language || '').trim();
      if (lang) opts.language = lang;

      const out = await _asr(audioPath, opts);
      if (out && typeof out.text === 'string') return out.text;
      if (Array.isArray(out) && out[0] && typeof out[0].text === 'string') {
        return out[0].text;
      }
      return '';
    },

    destroy() {
      _asr = null;
      _ready = false;
    },
  };
})();
