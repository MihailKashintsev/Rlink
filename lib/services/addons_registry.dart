import 'package:flutter/material.dart';

import '../ui/screens/music_screen.dart';

/// One add-on: a self-contained screen the messenger can host.
///
/// Built-in add-ons are listed in [addons] below. Custom (user) add-ons will
/// register here too once the loader lands — the shape is deliberately small
/// so an externally-described add-on can produce the same record.
class AddonInfo {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;

  /// Extra words the global search should match, beyond title/subtitle.
  final List<String> keywords;

  final Widget Function() open;

  const AddonInfo({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.open,
    this.keywords = const [],
  });

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return false;
    if (title.toLowerCase().contains(q)) return true;
    if (subtitle.toLowerCase().contains(q)) return true;
    return keywords.any((k) => k.toLowerCase().contains(q));
  }
}

/// Everything installed right now. Music is the reference add-on — it uses
/// only APIs a third-party add-on would get (catalog, playback, storage).
List<AddonInfo> addons() => [
      AddonInfo(
        id: 'rlink.music',
        title: 'Музыка',
        subtitle: 'Плеер, поиск, «Нравится», Линия, текст (бета)',
        icon: Icons.library_music_outlined,
        color: const Color(0xFF00BCD4),
        keywords: const [
          'music',
          'плеер',
          'player',
          'трек',
          'песня',
          'линия',
          'audius',
        ],
        open: () => const MusicScreen(),
      ),
    ];
