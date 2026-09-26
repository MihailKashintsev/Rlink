import 'dart:convert';

/// The plaintext sealed inside a DM `edit` / `delete` packet: `{"m": messageId,
/// "t": text}` (no `t` for a delete). The envelope signature covers only the
/// ciphertext, so the message id is bound INSIDE it — otherwise a captured valid
/// envelope could be re-sent paired with a different `messageId`.
String sealEditDeletePlain(String messageId, [String? text]) =>
    jsonEncode({'m': messageId, if (text != null) 't': text});

/// The text ("" for a delete) if [plain] is bound to [messageId]; null for
/// anything malformed or bound to a different message.
String? openEditDeletePlain(String plain, String messageId) {
  try {
    final j = jsonDecode(plain);
    if (j is! Map || j['m'] != messageId) return null;
    return (j['t'] as String?) ?? '';
  } catch (_) {
    return null;
  }
}
