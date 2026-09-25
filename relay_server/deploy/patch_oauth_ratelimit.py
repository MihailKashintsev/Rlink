# Idempotent in-place patch for the relay's oauth.dart. Adds a basic per-pairing
# rate limit to `GET oauth/<provider>/token?p=` (measured ~930 req/s, zero
# throttling). The pairing token itself already has 160 bits of secure
# randomness (Random.secure(), 20 bytes — see lib/services/relay_oauth_link.dart
# `_randomToken`), so this is defense-in-depth against resource exhaustion /
# scanning, not a fix for a guessable-token brute force (there isn't one).
import sys

p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if '_checkOauthTokenRate' in s:
    print('already patched')
    sys.exit(0)

marker = "String _key(String providerId, String pairing) => '$providerId:$pairing';"
assert s.count(marker) == 1, 'anchor not found — oauth.dart layout has changed'
s = s.replace(
    marker,
    marker
    + "\n\n"
    "const _oauthTokenRateWindow = Duration(minutes: 1);\n"
    "const _oauthTokenRateMax = 30;\n"
    "final Map<String, List<DateTime>> _oauthTokenRateLimits = {};\n\n"
    "bool _checkOauthTokenRate(String pairing) {\n"
    "  final now = DateTime.now();\n"
    "  final times = _oauthTokenRateLimits.putIfAbsent(pairing, () => []);\n"
    "  times.removeWhere((t) => now.difference(t) > _oauthTokenRateWindow);\n"
    "  if (times.length >= _oauthTokenRateMax) return false;\n"
    "  times.add(now);\n"
    "  return true;\n"
    "}",
    1,
)

old = (
    "  if (step == 'token') {\n"
    "    final p = request.url.queryParameters['p'] ?? '';\n"
    "    if (p.isEmpty) return _json({'ok': false, 'error': 'no_pairing'}, status: 400);"
)
assert s.count(old) == 1, 'token-step anchor not found'
s = s.replace(
    old,
    old
    + "\n"
    "    if (!_checkOauthTokenRate(p)) {\n"
    "      return _json({'ok': false, 'error': 'rate_limited'}, status: 429);\n"
    "    }",
    1,
)

open(p, 'w', encoding='utf-8').write(s)
print('patched')
