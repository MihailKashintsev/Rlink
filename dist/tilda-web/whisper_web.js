// whisper_web.js — Whisper transcription for Rlink Web via WASM
// Uses whisper.cpp compiled to WASM. Model cached in IndexedDB.

(function() {
  'use strict';

  const MODEL_URL = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin';
  const WASM_URL = 'https://cdn.jsdelivr.net/npm/whisper.wasm@1.2.0/dist/whisper.wasm';
  const DB_NAME = 'rlink-whisper';
  const DB_VERSION = 1;
  const STORE_NAME = 'models';

  let _whisperModule = null;
  let _modelData = null;
  let _ready = false;
  let _loading = false;
  let _lastError = '';

  // ---------- IndexedDB cache ----------
  function _openDB() {
    return new Promise((resolve, reject) => {
      const req = indexedDB.open(DB_NAME, DB_VERSION);
      req.onupgradeneeded = (e) => {
        const db = e.target.result;
        if (!db.objectStoreNames.contains(STORE_NAME)) {
          db.createObjectStore(STORE_NAME);
        }
      };
      req.onsuccess = (e) => resolve(e.target.result);
      req.onerror = (e) => reject(e.target.error);
    });
  }

  async function _loadModelFromCache() {
    const db = await _openDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORE_NAME, 'readonly');
      const store = tx.objectStore(STORE_NAME);
      const req = store.get('ggml-tiny');
      req.onsuccess = () => resolve(req.result || null);
      req.onerror = () => reject(req.error);
    });
  }

  async function _saveModelToCache(data) {
    const db = await _openDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORE_NAME, 'readwrite');
      const store = tx.objectStore(STORE_NAME);
      store.put(data, 'ggml-tiny');
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  // ---------- Model download with progress ----------
  async function _downloadModel(onProgress) {
    const resp = await fetch(MODEL_URL);
    if (!resp.ok) throw new Error('Model download failed: ' + resp.status);
    const total = parseInt(resp.headers.get('content-length') || '0', 10);
    const reader = resp.body.getReader();
    const chunks = [];
    let loaded = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      loaded += value.length;
      if (onProgress && total > 0) onProgress(loaded, total);
    }
    const all = new Uint8Array(loaded);
    let pos = 0;
    for (const c of chunks) {
      all.set(c, pos);
      pos += c.length;
    }
    return all;
  }

  // ---------- Load WASM module ----------
  async function _loadWasm() {
    if (_whisperModule) return _whisperModule;
    // whisper.wasm expects a global Module with specific interface
    const Module = {
      wasmBinary: null,
      onRuntimeInitialized: () => {},
      print: (text) => { console.log('[whisper]', text); },
      printErr: (text) => { console.warn('[whisper]', text); },
    };

    // Fetch WASM binary
    const wasmResp = await fetch(WASM_URL);
    if (!wasmResp.ok) throw new Error('WASM download failed: ' + wasmResp.status);
    Module.wasmBinary = await wasmResp.arrayBuffer();

    // The whisper.wasm module uses a factory pattern
    // We need to load the JS glue code that wraps the WASM
    const jsResp = await fetch(WASM_URL.replace('.wasm', '.js'));
    if (jsResp.ok) {
      const jsCode = await jsResp.text();
      // Execute the JS glue code which defines the Module factory
      const factoryFn = new Function('Module', jsCode + '\nreturn Module;');
      _whisperModule = factoryFn(Module);
    } else {
      // Fallback: try to load from CDN directly
      throw new Error('Whisper WASM JS glue not found. Ensure whisper.wasm.js is available.');
    }

    return _whisperModule;
  }

  // ---------- Public API ----------
  window.rlinkWhisper = {
    get isSupported() {
      return typeof WebAssembly !== 'undefined' &&
             typeof indexedDB !== 'undefined' &&
             typeof fetch !== 'undefined';
    },

    get isReady() { return _ready; },
    get lastError() { return _lastError; },

    /// Initialize: download model + load WASM. Calls onProgress(loaded, total) for model download.
    async init(onProgress) {
      if (_ready) return;
      if (_loading) {
        while (_loading) await new Promise(r => setTimeout(r, 100));
        if (_ready) return;
        if (_lastError) throw new Error(_lastError);
        return;
      }
      _loading = true;
      _lastError = '';
      try {
        // Try cache first
        let modelBytes = await _loadModelFromCache();
        if (!modelBytes) {
          console.log('[whisper-web] Downloading model (~78 MB for tiny)...');
          modelBytes = await _downloadModel(onProgress);
          await _saveModelToCache(modelBytes);
          console.log('[whisper-web] Model cached.');
        } else {
          console.log('[whisper-web] Using cached model (' + modelBytes.byteLength + ' bytes)');
        }
        _modelData = modelBytes;
        await _loadWasm();
        _ready = true;
      } catch (e) {
        _lastError = e.message || String(e);
        throw e;
      } finally {
        _loading = false;
      }
    },

    /// Transcribe an audio file. Returns text.
    async transcribe(audioPath, language) {
      if (!_ready) throw new Error('Whisper not initialized. Call init() first.');
      if (!_whisperModule) throw new Error('WASM module not loaded.');

      // Fetch audio file as ArrayBuffer
      const resp = await fetch(audioPath);
      if (!resp.ok) throw new Error('Audio file not found: ' + audioPath);
      const audioData = await resp.arrayBuffer();

      // Write model data to WASM memory
      const modelPtr = _whisperModule._malloc(_modelData.byteLength);
      _whisperModule.HEAPU8.set(new Uint8Array(_modelData), modelPtr);

      // Write audio data to WASM memory
      const audioPtr = _whisperModule._malloc(audioData.byteLength);
      _whisperModule.HEAPU8.set(new Uint8Array(audioData), audioPtr);

      // Call whisper (simplified — real impl uses whisper_full)
      // The actual whisper.wasm API may differ; this is a reference implementation
      try {
        const resultPtr = _whisperModule._whisper_transcribe(
          modelPtr, _modelData.byteLength,
          audioPtr, audioData.byteLength,
          language || 'ru'
        );
        if (!resultPtr) throw new Error('Transcription returned null');
        const text = _whisperModule.UTF8ToString(resultPtr);
        _whisperModule._free(resultPtr);
        return text;
      } finally {
        _whisperModule._free(modelPtr);
        _whisperModule._free(audioPtr);
      }
    },

    /// Free resources
    destroy() {
      _whisperModule = null;
      _modelData = null;
      _ready = false;
    }
  };
})();
