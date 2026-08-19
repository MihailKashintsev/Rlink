import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_l10n.dart';

import '../../models/contact.dart';
import '../../models/rls_sticker.dart';
import '../../models/rlv_sticker.dart';
import '../../models/sticker_pack.dart';
import '../../models/tgs_sticker.dart';
import '../../services/chat_storage_service.dart';
import '../../services/sticker_collection_service.dart';
import 'peer_stickers_screen.dart';
import 'rls_sticker_editor_screen.dart';
import 'rlv_sticker_editor_screen.dart';
import 'sticker_pack_detail_screen.dart';
import 'sticker_pack_editor_screen.dart';

/// Раздел «Стикеры»: наборы, создание, импорт от контакта.
class StickersHubScreen extends StatefulWidget {
  const StickersHubScreen({super.key});

  @override
  State<StickersHubScreen> createState() => _StickersHubScreenState();
}

class _StickersHubScreenState extends State<StickersHubScreen> {
  List<StickerPack> _packs = [];
  int _flatCount = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    StickerCollectionService.instance.version.addListener(_reload);
    unawaited(_reload());
  }

  @override
  void dispose() {
    StickerCollectionService.instance.version.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    await StickerCollectionService.instance.init();
    final packs = await StickerCollectionService.instance.loadPacks();
    final flat = await StickerCollectionService.instance.relativePathsValid();
    if (mounted) {
      setState(() {
        _packs = packs;
        _flatCount = flat.length;
        _loading = false;
      });
    }
  }

  Future<void> _openContactPickerForImport(BuildContext context) async {
    final contacts = await ChatStorageService.instance.getContacts();
    if (!context.mounted) return;
    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет контактов')),
      );
      return;
    }
    final picked = await showModalBottomSheet<Contact>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Чей набор посмотреть',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              ),
            ),
            for (final c in contacts)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: Color(c.avatarColor),
                  child: Text(
                    c.nickname.isNotEmpty ? c.nickname[0].toUpperCase() : '?',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                title: Text(c.nickname),
                onTap: () => Navigator.pop(ctx, c),
              ),
          ],
        ),
      ),
    );
    if (picked != null && context.mounted) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => PeerStickersScreen(
            peerId: picked.publicKeyHex,
            peerName: picked.nickname,
          ),
        ),
      );
    }
  }

  /// Opens the .rls editor and, on success, saves the exported bytes into the
  /// flat sticker collection (visible immediately via _reload — version bumps
  /// on registerStickerBytes). Works on both native and web.
  Future<void> _createAnimatedSticker(BuildContext context) async {
    final bytes = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const RlsStickerEditorScreen(),
      ),
    );
    if (bytes == null || !context.mounted) return;
    try {
      await StickerCollectionService.instance
          .registerStickerBytes(bytes: bytes, ext: rlsFileExtension);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Стикер сохранён в коллекцию. Добавьте его в набор ниже.'),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось сохранить стикер: $e')),
        );
      }
    }
  }

  /// Same flow as [_createAnimatedSticker], for the vector `.rlv` studio.
  Future<void> _createVectorSticker(BuildContext context) async {
    final bytes = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const RlvStickerEditorScreen(),
      ),
    );
    if (bytes == null || !context.mounted) return;
    try {
      await StickerCollectionService.instance
          .registerStickerBytes(bytes: bytes, ext: rlvFileExtension);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Стикер сохранён в коллекцию. Добавьте его в набор ниже.'),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось сохранить стикер: $e')),
        );
      }
    }
  }

  /// Imports a Telegram `.tgs` sticker byte-for-byte (it's already the final
  /// gzip container, nothing to re-encode) — playback-only, not editable.
  Future<void> _importTgsSticker(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['tgs'],
        withData: true,
      );
      final bytes = result?.files.single.bytes;
      if (bytes == null) return;
      if (gunzipTgsToLottieJson(bytes) == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Файл не похож на стикер Telegram (.tgs)')),
          );
        }
        return;
      }
      await StickerCollectionService.instance
          .registerStickerBytes(bytes: bytes, ext: tgsFileExtension);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Стикер сохранён в коллекцию. Добавьте его в набор ниже.'),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось импортировать стикер: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Стикеры'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Создать или импортировать стикер',
            icon: const Icon(Icons.add_circle_outline),
            onSelected: (v) {
              switch (v) {
                case 'animated':
                  _createAnimatedSticker(context);
                case 'vector':
                  _createVectorSticker(context);
                case 'tgs':
                  _importTgsSticker(context);
              }
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                value: 'vector',
                child: Text('Векторный (мини-студия)'),
              ),
              PopupMenuItem(
                value: 'animated',
                child: Text('Анимированный (растровый)'),
              ),
              PopupMenuItem(
                value: 'tgs',
                child: Text('Импорт из Telegram (.tgs)'),
              ),
            ],
          ),
          IconButton(
            tooltip: 'Стикеры из чата с контактом',
            icon: const Icon(Icons.person_search_outlined),
            onPressed: () => _openContactPickerForImport(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) => const StickerPackEditorScreen(),
            ),
          );
        },
        icon: const Icon(Icons.add),
        label: Text(AppL10n.t('cm_new_pack')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                children: [
                  Card(
                    child: ListTile(
                      leading: Icon(Icons.collections_outlined, color: cs.primary),
                      title: const Text('Все стикеры'),
                      subtitle: Text('$_flatCount шт. во вкладке «Стикеры»'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Мои наборы',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 4),
                  if (_packs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Наборов пока нет. Создайте из своих стикеров или '
                        'добавьте из переписки с контактом.',
                        style: TextStyle(color: cs.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                    )
                  else
                    ..._packs.map((p) {
                      final src = p.sourcePeerLabel ?? p.sourcePeerId;
                      return Card(
                        child: ListTile(
                          leading: Icon(Icons.folder_outlined, color: cs.primary),
                          title: Text(p.title),
                          subtitle: Text(
                            [
                              '${p.stickerRelPaths.length} стикеров',
                              if (src != null && src.isNotEmpty) 'от $src',
                            ].join(' · '),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            await Navigator.push<void>(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    StickerPackDetailScreen(packId: p.id),
                              ),
                            );
                          },
                        ),
                      );
                    }),
                ],
              ),
            ),
    );
  }
}
