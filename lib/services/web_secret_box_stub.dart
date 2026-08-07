// Non-web platforms never store secrets in a browser, so there is nothing to
// encrypt. encryptSecret returns null (caller keeps plaintext); decryptSecret
// passes the value straight through.

Future<String?> encryptSecret(String plaintext) async => null;

Future<String?> decryptSecret(String stored) async => stored;

bool secretBoxLooksEncrypted(String value) => false;
