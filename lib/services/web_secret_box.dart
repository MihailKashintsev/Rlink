// At-rest encryption for account secrets stored in the browser.
//
// On web, the identity private key and account bundle were mirrored as
// base64 *plaintext* into localStorage / sessionStorage / window.name — all
// readable in DevTools (F12). This box encrypts those values with an AES-GCM
// key that lives in IndexedDB as a **non-extractable** WebCrypto CryptoKey:
// its bytes can never be read back out via JS or DevTools, so the stored
// secrets show up only as ciphertext.
//
// It is deliberately fail-safe: if WebCrypto/IndexedDB isn't available,
// encryptSecret returns null and callers keep writing plaintext (exactly as
// before), and legacy plaintext already on disk still decrypts (passthrough).
export 'web_secret_box_stub.dart'
    if (dart.library.html) 'web_secret_box_web.dart';
