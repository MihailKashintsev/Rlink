import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/premium_status_screen.dart';
import '../../l10n/app_l10n.dart';

/// How often the suggestion is allowed to reappear (also the snooze length
/// when dismissed with the × — one code path for both).
const _kSuggestInterval = Duration(days: 5);

const _kLastShownKey = 'premium_suggestion_last_shown_ms';

/// True if enough time has passed since the suggestion was last shown (or
/// dismissed) to show it again. Callers combine this with `!PremiumService.
/// instance.isActive` and "no birthday banner showing" (that one wins the
/// single banner slot above the chat list).
Future<bool> shouldShowPremiumSuggestion() async {
  final prefs = await SharedPreferences.getInstance();
  final lastMs = prefs.getInt(_kLastShownKey);
  if (lastMs == null) return true;
  final last = DateTime.fromMillisecondsSinceEpoch(lastMs);
  return DateTime.now().difference(last) >= _kSuggestInterval;
}

Future<void> _markPremiumSuggestionShown() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_kLastShownKey, DateTime.now().millisecondsSinceEpoch);
}

/// Periodic "try Premium" nudge, shown above the chat list the same slot the
/// birthday banner uses (birthday wins when both would apply). Same visual
/// language as [BirthdayBanner] so it reads as part of the same banner family.
class PremiumSuggestionBanner extends StatefulWidget {
  final VoidCallback onDismissed;

  const PremiumSuggestionBanner({super.key, required this.onDismissed});

  @override
  State<PremiumSuggestionBanner> createState() =>
      _PremiumSuggestionBannerState();
}

class _PremiumSuggestionBannerState extends State<PremiumSuggestionBanner> {
  @override
  void initState() {
    super.initState();
    unawaited(_markPremiumSuggestionShown());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: [
            cs.tertiary.withValues(alpha: 0.18),
            cs.primary.withValues(alpha: 0.14),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: cs.tertiary.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          const Text('✨', style: TextStyle(fontSize: 24)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Rlink Premium',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w700)),
                Text(AppL10n.t('Цветной ник, больше каналов, конструктор ботов — от 48 ₽/мес'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 4),
          FilledButton(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PremiumStatusPage()),
            ),
            child: Text(AppL10n.t('Открыть')),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: widget.onDismissed,
          ),
        ],
      ),
    );
  }
}
