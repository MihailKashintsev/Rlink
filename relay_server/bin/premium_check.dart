// Self-check for the subscription arithmetic — the part that decides how much
// time a payment is worth. Run with the store pointed somewhere writable:
//
//   PREMIUM_STORE=/tmp/premium_test.json dart run bin/premium_check.dart
//
// No YooKassa involved: grants use the same _applyPayment path as payments.

import 'dart:io';

import 'premium.dart';

final _u1 = 'a' * 64;
final _u2 = 'b' * 64;

void main() {
  final path = Platform.environment['PREMIUM_STORE'];
  if (path == null) {
    stderr.writeln('set PREMIUM_STORE to a writable path');
    exit(2);
  }
  final f = File(path);
  if (f.existsSync()) f.deleteSync();

  // No subscription at all.
  assert(premiumUntilMs(_u1) == 0);

  // A grant lands roughly now + N days.
  final now = DateTime.now().millisecondsSinceEpoch;
  final after30 = adminGrantPremium(_u1, 30);
  final expected30 = now + 30 * 86400000;
  assert((after30 - expected30).abs() < 5000, 'grant 30d: $after30');
  assert(premiumUntilMs(_u1) == after30);

  // Extending stacks onto the remaining time instead of restarting it —
  // this is the property that must not regress: topping up early must never
  // cost the user days.
  final after60 = adminGrantPremium(_u1, 30);
  assert((after60 - after30 - 30 * 86400000).abs() < 5000, 'stack: $after60');

  // Users don't bleed into each other.
  assert(premiumUntilMs(_u2) == 0);
  adminGrantPremium(_u2, 7);
  assert(premiumUntilMs(_u1) == after60);

  // Junk ids and non-positive days are rejected, not stored.
  assert(adminGrantPremium('not-a-key', 30) == -1);
  assert(adminGrantPremium(_u1.toUpperCase(), 0) == -1);
  assert(premiumAll().length == 2);

  // Revoke clears one user and leaves the other alone.
  assert(adminRevokePremium(_u1));
  assert(premiumUntilMs(_u1) == 0);
  assert(premiumUntilMs(_u2) > 0);
  assert(!adminRevokePremium('short'));

  // Listing is newest-expiry-first.
  adminGrantPremium(_u1, 400);
  final all = premiumAll();
  assert(all.first['user_id'] == _u1, 'sort: ${all.first}');

  f.deleteSync();
  stdout.writeln('premium checks passed');
}
