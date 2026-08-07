import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/music_catalog_service.dart';
import '../../services/music_library_service.dart';
import '../../services/my_tracks_service.dart';

/// Pick profile music without storing a file anywhere: search the open
/// catalog, or paste a link someone shared. Returns the URL to play.
Future<String?> showMusicPickerSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _MusicPickerSheet(),
  );
}

class _MusicPickerSheet extends StatefulWidget {
  const _MusicPickerSheet();

  @override
  State<_MusicPickerSheet> createState() => _MusicPickerSheetState();
}

class _MusicPickerSheetState extends State<_MusicPickerSheet> {
  final _searchCtrl = TextEditingController();
  final _linkCtrl = TextEditingController();
  Timer? _debounce;
  List<CatalogTrack> _results = const [];
  bool _loading = false;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    // Your own library — uploaded to Drive + liked — shown before any search.
    MyTracksService.instance.load().then((_) {
      if (mounted) setState(() {});
    });
    MusicLibraryService.instance.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Uploaded tracks first, then liked; de-duplicated by URL.
  List<CatalogTrack> get _library {
    final seen = <String>{};
    final out = <CatalogTrack>[];
    for (final t in MyTracksService.instance.tracks.value) {
      final c = t.toCatalogTrack();
      if (seen.add(c.streamUrl)) out.add(c);
    }
    for (final ref in MusicLibraryService.instance.liked.value) {
      final r = parseMusicRef(ref);
      if (r.url.isNotEmpty && seen.add(r.url)) {
        out.add(CatalogTrack(
          title: r.title,
          artist: r.artist,
          streamUrl: r.url,
          artworkUrl: r.artwork,
          source: r.source,
        ));
      }
    }
    return out;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _linkCtrl.dispose();
    super.dispose();
  }

  void _onQuery(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _run(v));
  }

  Future<void> _run(String v) async {
    if (v.trim().length < 2) {
      setState(() {
        _results = const [];
        _searched = false;
      });
      return;
    }
    setState(() => _loading = true);
    final r = await MusicCatalogService.instance.search(v);
    if (!mounted) return;
    setState(() {
      _results = r;
      _loading = false;
      _searched = true;
    });
  }

  Widget _tile(CatalogTrack t, {bool mine = false}) => ListTile(
        leading: t.artworkUrl != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(t.artworkUrl!,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(Icons.album)),
              )
            : Icon(mine ? Icons.library_music_outlined : Icons.album),
        title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(t.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12)),
        onTap: () => Navigator.pop(context, encodeMusicRef(t)),
      );

  Widget _body(ColorScheme cs) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    // Active search → catalog results.
    if (_searched) {
      if (_results.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Ничего не нашлось',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant)),
          ),
        );
      }
      return ListView(children: [for (final t in _results) _tile(t)]);
    }
    // No search yet → your own library first.
    final lib = _library;
    if (lib.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Найдите трек, вставьте ссылку выше или загрузите свой в разделе Музыка',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Text('Моя библиотека',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant)),
      ),
      for (final t in lib) _tile(t, mine: true),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Музыка в профиле',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Трек играет по ссылке — ничего не хранится у нас и никому '
                  'не нужно его скачивать.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
            ),
            // ── Paste a shared link ───────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _linkCtrl,
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.link, size: 18),
                        hintText: 'Вставить ссылку на трек',
                        hintStyle: const TextStyle(fontSize: 13),
                        filled: true,
                        fillColor:
                            cs.surfaceContainerHighest.withValues(alpha: 0.5),
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      final v = _linkCtrl.text.trim();
                      if (!MusicCatalogService.instance.looksPlayableUrl(v)) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Нужна ссылка http(s)://')),
                        );
                        return;
                      }
                      Navigator.pop(context, v);
                    },
                    child: const Text('ОК'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // ── Catalog search ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: _onQuery,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: 'Поиск в каталоге Audius',
                  hintStyle: const TextStyle(fontSize: 13),
                  filled: true,
                  fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(child: _body(cs)),
          ],
        ),
      ),
    );
  }
}
