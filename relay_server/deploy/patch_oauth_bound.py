# Idempotent in-place patch for oauth.dart: bounds `_oauthTokenRateLimits`,
# which is keyed by the caller-supplied pairing token `p` and had no cleanup
# (unlike the WebSocket rate-limit maps, this HTTP endpoint has no connection
# lifecycle to hang a cleanup off) — verified: flooding distinct random `p`
# values grows the map forever.
import sys

p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if '_oauthTokenRateMaxEntries' in s:
    print('already patched')
    sys.exit(0)

old = (
    "bool _checkOauthTokenRate(String pairing) {\n"
    "  final now = DateTime.now();\n"
    "  final times = _oauthTokenRateLimits.putIfAbsent(pairing, () => []);\n"
    "  times.removeWhere((t) => now.difference(t) > _oauthTokenRateWindow);\n"
    "  if (times.length >= _oauthTokenRateMax) return false;\n"
    "  times.add(now);\n"
    "  return true;\n"
    "}"
)
assert s.count(old) == 1, 'anchor not found — oauth.dart layout has changed'
new = (
    "const _oauthTokenRateMaxEntries = 5000;\n\n"
    "bool _checkOauthTokenRate(String pairing) {\n"
    "  final now = DateTime.now();\n"
    "  final times = _oauthTokenRateLimits.putIfAbsent(pairing, () => []);\n"
    "  times.removeWhere((t) => now.difference(t) > _oauthTokenRateWindow);\n"
    "  if (times.length >= _oauthTokenRateMax) return false;\n"
    "  times.add(now);\n"
    "  if (_oauthTokenRateLimits.length > _oauthTokenRateMaxEntries) {\n"
    "    final keys = _oauthTokenRateLimits.keys.take(1000).toList();\n"
    "    for (final k in keys) {\n"
    "      _oauthTokenRateLimits.remove(k);\n"
    "    }\n"
    "  }\n"
    "  return true;\n"
    "}"
)
s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8').write(s)
print('patched')
