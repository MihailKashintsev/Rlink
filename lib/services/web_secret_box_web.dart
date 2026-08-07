import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

// package:web doesn't ship the WebCrypto algorithm dictionaries — declare them
// as JS object literals.
extension type _AesKeyGenParams._(JSObject _) implements JSObject {
  external factory _AesKeyGenParams({String name, int length});
}

extension type _AesGcmParams._(JSObject _) implements JSObject {
  external factory _AesGcmParams({String name, JSAny iv});
}

/// Marker for our AES-GCM ciphertext (base64 of iv|ciphertext).
const _prefix = 'e1:';

const _dbName = 'rlink_secret_box';
const _storeName = 'k';
const _keyId = 'aes_gcm_v1';

web.CryptoKey? _cryptoKey;
bool _disabled = false; // set once if the environment can't do WebCrypto
bool _selfTested = false;

bool secretBoxLooksEncrypted(String value) => value.startsWith(_prefix);

web.SubtleCrypto get _subtle => web.window.crypto.subtle;

Future<T> _reqToFuture<T extends JSAny?>(web.IDBRequest req) {
  final c = Completer<T>();
  req.onsuccess = ((web.Event _) {
    if (!c.isCompleted) c.complete(req.result as T);
  }).toJS;
  req.onerror = ((web.Event _) {
    if (!c.isCompleted) c.completeError(StateError('idb_error'));
  }).toJS;
  return c.future;
}

Future<web.IDBDatabase?> _openDb() async {
  try {
    final factory = web.window.indexedDB;
    final req = factory.open(_dbName, 1);
    req.onupgradeneeded = ((web.Event _) {
      final db = req.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    }).toJS;
    return await _reqToFuture<web.IDBDatabase>(req);
  } catch (_) {
    return null;
  }
}

Future<web.CryptoKey?> _loadStoredKey(web.IDBDatabase db) async {
  try {
    final txn = db.transaction(_storeName.toJS, 'readonly');
    final store = txn.objectStore(_storeName);
    final res = await _reqToFuture<JSAny?>(store.get(_keyId.toJS));
    if (res == null) return null;
    return res as web.CryptoKey;
  } catch (_) {
    return null;
  }
}

Future<void> _storeKey(web.IDBDatabase db, web.CryptoKey key) async {
  try {
    final txn = db.transaction(_storeName.toJS, 'readwrite');
    final store = txn.objectStore(_storeName);
    await _reqToFuture<JSAny?>(store.put(key, _keyId.toJS));
  } catch (_) {}
}

/// Get-or-create the non-extractable AES-GCM key, and prove it round-trips in
/// this browser before we trust it. On any failure the box disables itself and
/// callers keep plaintext — encryption never breaks storage.
Future<web.CryptoKey?> _getKey() async {
  if (_disabled) return null;
  if (_cryptoKey != null) return _cryptoKey;
  try {
    final db = await _openDb();
    web.CryptoKey? key = db == null ? null : await _loadStoredKey(db);
    if (key == null) {
      final generated = await _subtle
          .generateKey(
            _AesKeyGenParams(name: 'AES-GCM', length: 256),
            false, // extractable = false → bytes never leave WebCrypto
            <JSString>['encrypt'.toJS, 'decrypt'.toJS].toJS,
          )
          .toDart;
      key = generated as web.CryptoKey;
      if (db != null) await _storeKey(db, key);
    }
    _cryptoKey = key;
    if (!_selfTested) {
      final probe = await _encryptWith(key, 'rlink-selftest');
      final back = probe == null ? null : await _decryptWith(key, probe);
      if (back != 'rlink-selftest') {
        _disabled = true;
        _cryptoKey = null;
        return null;
      }
      _selfTested = true;
    }
    return _cryptoKey;
  } catch (_) {
    _disabled = true;
    return null;
  }
}

Future<String?> _encryptWith(web.CryptoKey key, String plaintext) async {
  final ivJs = Uint8List(12).toJS;
  web.window.crypto.getRandomValues(ivJs);
  final iv = ivJs.toDart;
  final data = Uint8List.fromList(utf8.encode(plaintext));
  final buf = await _subtle
      .encrypt(
        _AesGcmParams(name: 'AES-GCM', iv: iv.toJS),
        key,
        data.toJS,
      )
      .toDart;
  final ct = (buf as JSArrayBuffer).toDart.asUint8List();
  final out = Uint8List(iv.length + ct.length)
    ..setAll(0, iv)
    ..setAll(iv.length, ct);
  return _prefix + base64.encode(out);
}

Future<String?> _decryptWith(web.CryptoKey key, String stored) async {
  final raw = base64.decode(stored.substring(_prefix.length));
  if (raw.length <= 12) return null;
  final iv = raw.sublist(0, 12);
  final ct = raw.sublist(12);
  final buf = await _subtle
      .decrypt(
        _AesGcmParams(name: 'AES-GCM', iv: iv.toJS),
        key,
        ct.toJS,
      )
      .toDart;
  return utf8.decode((buf as JSArrayBuffer).toDart.asUint8List());
}

Future<String?> encryptSecret(String plaintext) async {
  if (_disabled) return null;
  try {
    final key = await _getKey();
    if (key == null) return null;
    return _encryptWith(key, plaintext);
  } catch (_) {
    return null;
  }
}

Future<String?> decryptSecret(String stored) async {
  // Legacy / non-encrypted values pass straight through.
  if (!stored.startsWith(_prefix)) return stored;
  try {
    final key = await _getKey();
    if (key == null) return null;
    return await _decryptWith(key, stored);
  } catch (_) {
    // Undecryptable ciphertext (e.g. key evicted) → null so the caller falls
    // through to another store / OPFS hydrate, never a crash or data loss.
    return null;
  }
}
