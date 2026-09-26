import 'dart:convert';

/// The plaintext sealed inside a DM `edit` / `delete` packet: `{"m": messageId,
/// "t": text, "ts": epochMs}` (no `t` for a delete). The envelope signature
/// covers only the ciphertext, so the message id AND a timestamp are bound
/// INSIDE it — otherwise a captured valid envelope (relay sees the ciphertext
/// to route it) could be re-sent later, either against a different message
/// (closed by `m`) or, without `ts`, replayed to roll a message's text back
/// to an older version at any time. The receiver only accepts a `ts` newer
/// than the last one it applied for that message (see
/// `SignedAction.acceptNewer('edit:$messageId', ts)` at the call site).
String sealEditDeletePlain(String messageId, int tsMs, [String? text]) =>
    jsonEncode({'m': messageId, 'ts': tsMs, if (text != null) 't': text});

/// The (text, ts) if [plain] is bound to [messageId]; text is `''` for a
/// delete. Null for anything malformed, bound to a different message, or
/// missing a timestamp.
(String, int)? openEditDeletePlain(String plain, String messageId) {
  try {
    final j = jsonDecode(plain);
    if (j is! Map || j['m'] != messageId) return null;
    final ts = j['ts'];
    if (ts is! num) return null;
    return ((j['t'] as String?) ?? '', ts.toInt());
  } catch (_) {
    return null;
  }
}

/// Whether a signed edit/delete from the OTHER side of a DM may be applied to
/// a message this device already has. A contact may only touch a message
/// they themselves sent (`!existingIsOutgoing`) — the one deliberate
/// exception is a shared todo/calendar item, mutual state both sides are
/// meant to update regardless of who originally sent it. Delete never gets
/// that exception (pass `isMerge: false` there): there is no legitimate
/// reason for a contact to delete a message I sent.
bool editDeleteAllowedForMessage(
        {required bool existingIsOutgoing, required bool isMerge}) =>
    isMerge || !existingIsOutgoing;
