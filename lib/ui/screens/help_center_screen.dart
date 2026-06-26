import 'package:flutter/material.dart';

import '../../l10n/app_l10n.dart';
import 'intro_promo_screen.dart';
import 'guide_tour_screen.dart';

/// "How Rlink works" — a table of contents that splits the guide into topics,
/// so the user can jump straight to what they need instead of watching it all.
class HelpCenterScreen extends StatelessWidget {
  const HelpCenterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(AppL10n.t('help_center_title'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 28),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 14),
            child: Text(
              AppL10n.t('help_center_sub'),
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
            ),
          ),
          // ── Watch (the animations) ──
          _HelpTile(
            icon: Icons.play_circle_fill_rounded,
            color: cs.primary,
            title: AppL10n.t('help_watch_intro_t'),
            subtitle: AppL10n.t('help_watch_intro_s'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const IntroPromoScreen(markSeenOnFinish: false),
            )),
          ),
          _HelpTile(
            icon: Icons.explore_rounded,
            color: cs.primary,
            title: AppL10n.t('help_watch_tour_t'),
            subtitle: AppL10n.t('help_watch_tour_s'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const GuideTourScreen(markSeenOnFinish: false),
            )),
          ),
          const SizedBox(height: 8),
          // ── Step-by-step articles ──
          for (final a in _articles)
            _HelpTile(
              icon: a.icon,
              color: cs.secondary,
              title: AppL10n.t(a.titleKey),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => _HelpArticleScreen(article: a),
              )),
            ),
        ],
      ),
    );
  }
}

class _Article {
  final IconData icon;
  final String titleKey;
  final String bodyKey;
  const _Article(this.icon, this.titleKey, this.bodyKey);
}

const _articles = <_Article>[
  _Article(Icons.person_search_rounded, 'help_find_t', 'help_find_b'),
  _Article(Icons.bluetooth_searching_rounded, 'help_exchange_t',
      'help_exchange_b'),
  _Article(Icons.badge_rounded, 'help_profile_t', 'help_profile_b'),
  _Article(Icons.group_add_rounded, 'help_group_t', 'help_group_b'),
  _Article(Icons.campaign_rounded, 'help_channel_t', 'help_channel_b'),
  _Article(Icons.cloud_sync_rounded, 'help_google_t', 'help_google_b'),
  _Article(Icons.smart_toy_rounded, 'help_bots_t', 'help_bots_b'),
];

class _HelpTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  const _HelpTile({
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      color: cs.surfaceContainerHigh,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 24),
        ),
        title: Text(title,
            style:
                const TextStyle(fontWeight: FontWeight.w600, fontSize: 15.5)),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
        onTap: onTap,
      ),
    );
  }
}

class _HelpArticleScreen extends StatelessWidget {
  final _Article article;
  const _HelpArticleScreen({required this.article});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final steps = AppL10n.t(article.bodyKey)
        .split('\n')
        .where((e) => e.trim().isNotEmpty)
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text(AppL10n.t(article.titleKey))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 32),
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    cs.primary,
                    Color.lerp(cs.primary, cs.tertiary, 0.6)!,
                  ]),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(article.icon, color: cs.onPrimary, size: 30),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  AppL10n.t(article.titleKey),
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.16),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                          color: cs.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 15),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        steps[i],
                        style: TextStyle(
                            fontSize: 16, height: 1.4, color: cs.onSurface),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
