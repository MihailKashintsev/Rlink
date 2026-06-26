import 'dart:math' as math;

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
          _HelpTile(
            icon: Icons.play_circle_fill_rounded,
            color: const Color(0xFF1DB954),
            title: AppL10n.t('help_watch_intro_t'),
            subtitle: AppL10n.t('help_watch_intro_s'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const IntroPromoScreen(markSeenOnFinish: false),
            )),
          ),
          _HelpTile(
            icon: Icons.explore_rounded,
            color: const Color(0xFF42A5F5),
            title: AppL10n.t('help_watch_tour_t'),
            subtitle: AppL10n.t('help_watch_tour_s'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const GuideTourScreen(markSeenOnFinish: false),
            )),
          ),
          const SizedBox(height: 8),
          for (final a in _articles)
            _HelpTile(
              icon: a.icon,
              color: a.color,
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

enum _Art { find, exchange, profile, group, channel, google, bots }

class _Article {
  final IconData icon;
  final Color color;
  final String titleKey;
  final String bodyKey;
  final _Art art;
  const _Article(this.icon, this.color, this.titleKey, this.bodyKey, this.art);
}

const _articles = <_Article>[
  _Article(Icons.person_search_rounded, Color(0xFF42A5F5), 'help_find_t',
      'help_find_b', _Art.find),
  _Article(Icons.bluetooth_searching_rounded, Color(0xFF26C6DA),
      'help_exchange_t', 'help_exchange_b', _Art.exchange),
  _Article(Icons.badge_rounded, Color(0xFF7C4DFF), 'help_profile_t',
      'help_profile_b', _Art.profile),
  _Article(Icons.group_add_rounded, Color(0xFF26A69A), 'help_group_t',
      'help_group_b', _Art.group),
  _Article(Icons.campaign_rounded, Color(0xFFFFA726), 'help_channel_t',
      'help_channel_b', _Art.channel),
  _Article(Icons.cloud_sync_rounded, Color(0xFF66BB6A), 'help_google_t',
      'help_google_b', _Art.google),
  _Article(Icons.smart_toy_rounded, Color(0xFFEC407A), 'help_bots_t',
      'help_bots_b', _Art.bots),
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
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [color, Color.lerp(color, Colors.black, 0.25)!],
            ),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, color: Colors.white, size: 24),
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

class _HelpArticleScreen extends StatefulWidget {
  final _Article article;
  const _HelpArticleScreen({required this.article});

  @override
  State<_HelpArticleScreen> createState() => _HelpArticleScreenState();
}

class _HelpArticleScreenState extends State<_HelpArticleScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _amb = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _amb.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.article;
    final cs = Theme.of(context).colorScheme;
    final steps = AppL10n.t(a.bodyKey)
        .split('\n')
        .where((e) => e.trim().isNotEmpty)
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text(AppL10n.t(a.titleKey))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          // Animated illustration with an arrow pointing where to act.
          _ArticleArt(art: a.art, color: a.color, anim: _amb),
          const SizedBox(height: 24),
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
                      color: a.color.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                    ),
                    child: Text('${i + 1}',
                        style: TextStyle(
                            color: a.color,
                            fontWeight: FontWeight.w700,
                            fontSize: 15)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(steps[i],
                          style: TextStyle(
                              fontSize: 16, height: 1.4, color: cs.onSurface)),
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

/// A small theme-aware mock of the relevant control with a bouncing arrow +
/// pulsing highlight pointing exactly where the user should act.
class _ArticleArt extends StatelessWidget {
  final _Art art;
  final Color color;
  final Animation<double> anim;
  const _ArticleArt(
      {required this.art, required this.color, required this.anim});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          // Caption "Сюда / Here"
          Text(
            AppL10n.t('help_here'),
            style: TextStyle(
                color: color, fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 6),
          // Bouncing down-arrow
          AnimatedBuilder(
            animation: anim,
            builder: (_, __) => Transform.translate(
              offset: Offset(0, math.sin(anim.value * math.pi) * 7),
              child: Icon(Icons.keyboard_double_arrow_down_rounded,
                  color: color, size: 30),
            ),
          ),
          const SizedBox(height: 8),
          // Highlighted target element (pulsing border)
          AnimatedBuilder(
            animation: anim,
            builder: (_, child) {
              final p = anim.value;
              return Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: color.withValues(alpha: 0.55 + 0.45 * p),
                    width: 2.4,
                  ),
                  boxShadow: [
                    BoxShadow(
                        color: color.withValues(alpha: 0.18 + 0.18 * p),
                        blurRadius: 14 + 8 * p),
                  ],
                ),
                child: child,
              );
            },
            child: _target(cs),
          ),
        ],
      ),
    );
  }

  Widget _wrap(ColorScheme cs, Widget child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      );

  Widget _label(ColorScheme cs, String text,
          {Color? c, FontWeight w = FontWeight.w500}) =>
      Text(text,
          style: TextStyle(
              color: c ?? cs.onSurface, fontSize: 15.5, fontWeight: w));

  Widget _target(ColorScheme cs) {
    switch (art) {
      case _Art.find:
        return _wrap(
          cs,
          Row(children: [
            Icon(Icons.search, color: cs.onSurfaceVariant, size: 22),
            const SizedBox(width: 10),
            Flexible(
                child: _label(cs, AppL10n.t('il_name_user_code'),
                    c: cs.onSurfaceVariant)),
          ]),
        );
      case _Art.profile:
        return _wrap(
          cs,
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text('@',
                style: TextStyle(
                    color: color, fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(width: 6),
            _label(cs, AppL10n.t('il_username').replaceAll('@', ''),
                w: FontWeight.w600),
          ]),
        );
      case _Art.exchange:
        return _wrap(
          cs,
          Row(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(radius: 14, backgroundColor: color, child: const Text('🦊', style: TextStyle(fontSize: 14))),
            const SizedBox(width: 10),
            _label(cs, AppL10n.t('il_nearby_device')),
            const SizedBox(width: 10),
            Icon(Icons.bluetooth_rounded, color: color, size: 20),
          ]),
        );
      case _Art.group:
        return _wrap(
          cs,
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.group_add_outlined, color: color, size: 22),
            const SizedBox(width: 10),
            _label(cs, AppL10n.t('il_new_group'), w: FontWeight.w600),
          ]),
        );
      case _Art.channel:
        return _wrap(
          cs,
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.campaign_outlined, color: color, size: 22),
            const SizedBox(width: 10),
            _label(cs, AppL10n.t('il_new_channel'), w: FontWeight.w600),
          ]),
        );
      case _Art.google:
        return _wrap(
          cs,
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_outlined, color: color, size: 22),
            const SizedBox(width: 10),
            _label(cs, 'Google Drive', w: FontWeight.w600),
            const SizedBox(width: 12),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                  color: color, borderRadius: BorderRadius.circular(10)),
              child: Text(AppL10n.t('il_connect'),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
        );
      case _Art.bots:
        return _wrap(
          cs,
          Row(mainAxisSize: MainAxisSize.min, children: [
            for (final c in const ['/start', '/help'])
              Container(
                margin: const EdgeInsets.only(right: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  border: Border.all(color: color.withValues(alpha: 0.6)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(c,
                    style: TextStyle(
                        color: color,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ),
          ]),
        );
    }
  }
}
