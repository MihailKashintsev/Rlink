# Idempotent in-place patch: adds the `backup_redeemed` advisory endpoint the
# new file-based account backup feature uses (Settings -> "Резервная копия
# аккаунта" / onboarding -> "У меня есть файл переноса"). See the doc comment
# on `_redeemedBackups` below for exactly what this does and doesn't
# guarantee — it is a hint to the person restoring a backup ("this file was
# already opened before, at <time>"), never a security boundary: a copied
# file's key material has full account power the moment it's decrypted
# locally, regardless of anything the server remembers.
import sys

p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if '_handleBackupRedeemed' in s:
    print('already patched')
    sys.exit(0)


def rep(old, new, cnt=1):
    global s
    n = s.count(old)
    assert n == cnt, (n, cnt, old[:90])
    s = s.replace(old, new, cnt)


rep(
    "    case 'admin_password_update':\n"
    "      _handleAdminPasswordUpdate(user, msg);\n"
    "      break;\n",
    "    case 'admin_password_update':\n"
    "      _handleAdminPasswordUpdate(user, msg);\n"
    "      break;\n"
    "    case 'backup_redeemed':\n"
    "      _handleBackupRedeemed(user, msg);\n"
    "      break;\n",
)

marker = "void _handleAdminPasswordUpdate(_User user, Map<String, dynamic> msg) {"
assert s.count(marker) == 1, 'anchor not found — server.dart layout has changed'
handler = (
    "final Map<String, Map<String, String>> _redeemedBackups = {};\n"
    "const _maxRedeemedBackupsTracked = 20000;\n\n"
    "void _handleBackupRedeemed(_User user, Map<String, dynamic> msg) {\n"
    "  final reqId = _jsonString(msg['reqId']).trim();\n"
    "  void ack(Map<String, dynamic> body) {\n"
    "    try {\n"
    "      user.ws.sink.add(jsonEncode({\n"
    "        'type': 'backup_redeemed_ack',\n"
    "        if (reqId.isNotEmpty) 'reqId': reqId,\n"
    "        ...body,\n"
    "      }));\n"
    "    } catch (_) {}\n"
    "  }\n"
    "  final backupId = _jsonString(msg['backupId']).trim();\n"
    "  if (backupId.isEmpty || backupId.length > 100) {\n"
    "    ack({'ok': false, 'error': 'bad_backup_id'});\n"
    "    return;\n"
    "  }\n"
    "  if (!user.verified) {\n"
    "    ack({'ok': false, 'error': 'unverified'});\n"
    "    return;\n"
    "  }\n"
    "  final existing = _redeemedBackups[backupId];\n"
    "  if (existing == null) {\n"
    "    _redeemedBackups[backupId] = {\n"
    "      'at': DateTime.now().toIso8601String(),\n"
    "    };\n"
    "    if (_redeemedBackups.length > _maxRedeemedBackupsTracked) {\n"
    "      _redeemedBackups.remove(_redeemedBackups.keys.first);\n"
    "    }\n"
    "    ack({'ok': true, 'alreadyUsed': false});\n"
    "  } else {\n"
    "    ack({'ok': true, 'alreadyUsed': true, 'firstAt': existing['at']});\n"
    "  }\n"
    "}\n\n"
) + marker
s = s.replace(marker, handler, 1)

open(p, 'w', encoding='utf-8').write(s)
print('patched')
