// whisper_web.js — Whisper transcription for Rlink Web via transformers.js
//
// Real in-browser speech-to-text using Hugging Face transformers.js
// (@huggingface/transformers). It downloads an ONNX Whisper model once,
// caches it in the browser Cache API, decodes + resamples audio to 16 kHz
// itself, and runs inference on WebGPU when the browser has it (much faster,
// so a bigger/more accurate model becomes usable), falling back to the WASM
// backend + the tiny model everywhere else (Safari, older browsers).
//
// The public API on window.rlinkWhisper exposes isSupported/isReady/lastError
// as METHODS (functions) — the Dart bridge (whisper_web_service_web.dart)
// calls them via callMethod(), so they must be callable, not getters.

(function () {
  'use strict';

  // ESM build of transformers.js, loaded lazily via dynamic import on first use.
  const TRANSFORMERS_URL =
    'https://cdn.jsdelivr.net/npm/@huggingface/transformers@3';
  // Multilingual models (Russian included). distil-whisper is deliberately NOT
  // used: it is English-only.
  //   WebGPU  → small, q4-quantised: ~5x the accuracy budget of tiny at a
  //             download people will actually wait for.
  //   WASM    → tiny, as before: anything larger is unusably slow on CPU.
  const MODEL_WEBGPU = 'onnx-community/whisper-small';
  const MODEL_WASM = 'Xenova/whisper-tiny';

  let _asr = null;
  let _ready = false;
  let _loading = false;
  let _lastError = '';
  let _backend = '';
  let _model = '';

  async function hasWebGPU() {
    try {
      if (!navigator.gpu) return false;
      // Presence of navigator.gpu is not enough — a real adapter must exist.
      const adapter = await navigator.gpu.requestAdapter();
      return !!adapter;
    } catch (_) {
      return false;
    }
  }

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

        const report = (p) => {
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
        };

        const build = async (model, opts) =>
          pipeline('automatic-speech-recognition', model, {
            ...opts,
            progress_callback: report,
          });

        const gpu = await hasWebGPU();
        if (gpu) {
          try {
            _asr = await build(MODEL_WEBGPU, {
              device: 'webgpu',
              dtype: {
                encoder_model: 'q4',
                decoder_model_merged: 'q4',
              },
            });
            _backend = 'webgpu';
            _model = MODEL_WEBGPU;
          } catch (e) {
            // A GPU can still fail mid-load (driver, memory, shader limits) —
            // never leave the user with no transcription because of it.
            console.warn('[whisper-web] WebGPU init failed, falling back:', e);
            _asr = null;
          }
        }

        if (!_asr) {
          _asr = await build(MODEL_WASM, { device: 'wasm' });
          _backend = 'wasm';
          _model = MODEL_WASM;
        }

        _ready = true;
        console.log(
          '[whisper-web] ASR ready — ' + _model + ' on ' + _backend);
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

    /// 'webgpu' | 'wasm' | '' — what actually loaded, for the settings UI.
    backend() {
      return _backend;
    },

    /// Model id that actually loaded.
    activeModel() {
      return _model;
    },

    /// Same as transcribe(), but time-aligned: returns a JSON string of
    /// [{startMs, endMs, text}] so the UI can highlight the current line.
    async transcribeSegments(audioPath, language) {
      if (!_ready || !_asr) {
        throw new Error('Whisper not initialized. Call init() first.');
      }
      const opts = {
        task: 'transcribe',
        chunk_length_s: 30,
        stride_length_s: 5,
        return_timestamps: true,
      };
      const lang = (language || '').trim();
      if (lang) opts.language = lang;

      const out = await _asr(audioPath, opts);
      const chunks = (out && out.chunks) || [];
      const segs = chunks.map((c) => {
        const ts = c.timestamp || [];
        const s = typeof ts[0] === 'number' ? ts[0] : 0;
        const e = typeof ts[1] === 'number' ? ts[1] : s;
        return {
          startMs: Math.round(s * 1000),
          endMs: Math.round(e * 1000),
          text: (c.text || '').trim(),
        };
      });
      return JSON.stringify(segs);
    },

    destroy() {
      _asr = null;
      _ready = false;
      _backend = '';
      _model = '';
    },
  };
})();
