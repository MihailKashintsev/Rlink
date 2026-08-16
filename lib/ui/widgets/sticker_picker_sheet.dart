import 'package:flutter/material.dart';

import '../../models/sticker_pack.dart';
import '../../services/sticker_collection_service.dart';
import 'channel_feed_image.dart';

/// Нижняя панель выбора стикера: паки — рядом маленьких иконок сверху (как в
/// пикере эмодзи), сетка выбранного пака под ним.
Future<void> showStickerPickerSheet(
  BuildContext context, {
  required Future<void> Function(String absolutePath) onPickedSticker,
}) async {
  await StickerCollectionService.instance.init();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final h = MediaQuery.sizeOf(ctx).height * 0.58;
      return SafeArea(
        child: SizedBox(
          height: h,
          child: FutureBuilder<List<StickerPack>>(
            future: StickerCollectionService.instance.loadPacks(),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final packs = snap.data ?? const <StickerPack>[];
              return _StickerPickerBody(
                packs: packs,
                onPicked: (abs) async {
                  Navigator.pop(ctx);
                  await onPickedSticker(abs);
                },
              );
            },
          ),
        ),
      );
    },
  );
}

class _StickerPickerBody extends StatefulWidget {
  final List<StickerPack> packs;
  final Future<void> Function(String absolutePath) onPicked;

  const _StickerPickerBody({
    required this.packs,
    required this.onPicked,
  });

  @override
  State<_StickerPickerBody> createState() => _StickerPickerBodyState();
}

class _StickerPickerBodyState extends State<_StickerPickerBody> {
  int _sel = 0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final packs = widget.packs;
    return Column(
      children: [
        if (packs.isEmpty)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Нет наборов. Создайте набор в разделе стикеров.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
            ),
          )
        else ...[
          // ── One row of small pack icons, like the emoji picker's tab row ──
          SizedBox(
            height: 44,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: packs.length,
              itemBuilder: (_, i) {
                final pack = packs[i];
                final selected = i == _sel.clamp(0, packs.length - 1);
                final firstRel = pack.stickerRelPaths.isNotEmpty
                    ? pack.stickerRelPaths.first
                    : null;
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
                      child: firstRel == null
                          ? const Icon(Icons.folder_outlined, size: 20)
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: _PackThumb(relPath: firstRel),
                            ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _StickerPackPickerGrid(
              key: ValueKey(packs[_sel.clamp(0, packs.length - 1)].id),
              packId: packs[_sel.clamp(0, packs.length - 1)].id,
              onPicked: widget.onPicked,
            ),
          ),
        ],
      ],
    );
  }
}

class _PackThumb extends StatelessWidget {
  final String relPath;
  const _PackThumb({required this.relPath});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: StickerCollectionService.instance.absoluteFileForRel(relPath),
      builder: (context, snap) {
        final f = snap.data;
        if (f == null) return const Icon(Icons.image_outlined, size: 18);
        return storedImage(f, width: 26, height: 26, fit: BoxFit.cover);
      },
    );
  }
}

class _StickerPackPickerGrid extends StatelessWidget {
  final String packId;
  final Future<void> Function(String absolutePath) onPicked;

  const _StickerPackPickerGrid({
    super.key,
    required this.packId,
    required this.onPicked,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: StickerCollectionService.instance.stickerFilesForPack(packId),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final files = snap.data ?? const <String>[];
        if (files.isEmpty) {
          return Center(
            child: Text(
              'В наборе нет файлов',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 5,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: files.length,
          itemBuilder: (context, i) {
            final f = files[i];
            return Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onPicked(f),
                child: storedImage(f, fit: BoxFit.cover),
              ),
            );
          },
        );
      },
    );
  }
}
