import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' as epf;
import 'package:flutter/material.dart';

import '../../models/emoji_pack.dart';
import '../../services/emoji_pack_service.dart';

/// One picker for everything: custom packs and the official set share a single
/// row of tabs at the top, the grid below shows whatever is selected, and the
/// search box matches official names *and* custom `:shortcodes:`.
///
/// Emits either a unicode emoji or `:shortcode:` — same contract the old
/// split picker used, so callers didn't change.
class UnifiedEmojiPicker extends StatefulWidget {
  final void Function(String value) onSelected;

  /// Rendered above the tab row (e.g. a "recent" strip) when provided.
  final Widget? header;

  const UnifiedEmojiPicker({super.key, required this.onSelected, this.header});

  @override
  State<UnifiedEmojiPicker> createState() => _UnifiedEmojiPickerState();
}

class _Item {
  final String value; // what we emit
  final String name; // search key
  final ImageProvider? image; // custom emoji (may be animated)
  const _Item({required this.value, required this.name, this.image});
}

class _Source {
  final String label;
  final String glyph; // tab glyph (unicode) — empty when [image] is used
  final ImageProvider? image; // custom pack cover
  final List<_Item> items;
  const _Source({
    required this.label,
    required this.items,
    this.glyph = '',
    this.image,
  });
}

class _UnifiedEmojiPickerState extends State<UnifiedEmojiPicker> {
  List<_Source> _sources = const [];
  int _sel = 0;
  String _query = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _build();
  }

  Future<void> _build() async {
    List<EmojiPack> packs = const [];
    try {
      packs = await EmojiPackService.instance.loadPacks();
    } catch (_) {}

    final sources = <_Source>[];
    // Custom packs first — they're the user's own.
    for (final p in packs) {
      if (p.emojis.isEmpty) continue;
      final items = <_Item>[];
      for (final e in p.emojis) {
        items.add(_Item(
          value: ':${e.shortcode}:',
          name: e.shortcode,
          image: EmojiPackService.instance.emojiImageProvider(e.shortcode),
        ));
      }
      sources.add(_Source(
        label: p.name,
        items: items,
        image: items.first.image,
      ));
    }
    // Official set, one tab per category.
    for (final cat in epf.defaultEmojiSet) {
      if (cat.emoji.isEmpty) continue;
      sources.add(_Source(
        label: cat.category.name,
        glyph: cat.emoji.first.emoji,
        items: [
          for (final e in cat.emoji) _Item(value: e.emoji, name: e.name),
        ],
      ));
    }
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _loading = false;
    });
  }

  List<_Item> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) {
      if (_sources.isEmpty) return const [];
      return _sources[_sel.clamp(0, _sources.length - 1)].items;
    }
    // Search spans every source: official names are keywords, custom names
    // are the codes people type as :like_this:.
    final out = <_Item>[];
    for (final s in _sources) {
      for (final i in s.items) {
        if (i.name.toLowerCase().contains(q)) out.add(i);
        if (out.length >= 200) return out;
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = _visible;
    final searching = _query.trim().isNotEmpty;

    return Column(
      children: [
        if (widget.header != null) widget.header!,
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: 'Поиск: имя или :код:',
              hintStyle: const TextStyle(fontSize: 13),
              filled: true,
              fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        // ── One row: custom packs + official categories together ──────────
        if (!searching)
          SizedBox(
            height: 40,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _sources.length,
              itemBuilder: (_, i) {
                final s = _sources[i];
                final selected = i == _sel;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() => _sel = i),
                    child: Container(
                      width: 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? cs.primary.withValues(alpha: 0.16)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: s.image != null
                          ? Image(
                              image: s.image!,
                              width: 22,
                              height: 22,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.folder, size: 18),
                            )
                          : Text(s.glyph,
                              style: const TextStyle(fontSize: 19)),
                    ),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 4),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text('Ничего не найдено',
                      style: TextStyle(color: cs.onSurfaceVariant)),
                )
              : GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 8,
                    mainAxisSpacing: 2,
                    crossAxisSpacing: 2,
                  ),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final it = items[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => widget.onSelected(it.value),
                      child: Center(
                        // Animated custom emoji (GIF/WebP) play on their own
                        // in an Image — no extra work needed.
                        child: it.image != null
                            ? Image(
                                image: it.image!,
                                width: 28,
                                height: 28,
                                errorBuilder: (_, __, ___) =>
                                    const SizedBox.shrink(),
                              )
                            : Text(it.value,
                                style: const TextStyle(fontSize: 24)),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
