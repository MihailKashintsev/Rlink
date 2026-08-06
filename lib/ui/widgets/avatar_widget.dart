import 'dart:io';
import 'dart:math' as math;
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/sticker_pack.dart';
import '../../utils/web_file_store.dart';
import '../../services/app_settings.dart';
import '../../services/emoji_pack_service.dart';
import 'unified_emoji_picker.dart';
import '../../services/image_service.dart';
import '../../services/sticker_collection_service.dart';

enum AvatarPresenceTransport { bluetooth, internet, wifiDirect }

class AvatarWidget extends StatelessWidget {
  final String initials;
  final int color;
  final String emoji; // если не пустой — показываем эмодзи вместо инициалов
  final String? imagePath; // если задан — показываем фото поверх всего
  final double size;
  final bool isOnline;
  final List<AvatarPresenceTransport> onlineTransports;
  final bool hasStory; // показывать ли кольцо сторис
  final bool hasUnviewedStory; // непросмотренная сторис — яркий градиент

  /// Corner radius; null = circle. Used to morph the avatar into a square
  /// when the profile header is pulled open.
  final double? cornerRadius;

  const AvatarWidget({
    super.key,
    required this.initials,
    required this.color,
    this.emoji = '',
    this.imagePath,
    this.size = 48,
    this.isOnline = false,
    this.onlineTransports = const [],
    this.hasStory = false,
    this.hasUnviewedStory = false,
    this.cornerRadius,
  });

  static final RegExp _shortcodeRe = RegExp(r'^:([a-zA-Z0-9_]{1,48}):$');

  @override
  Widget build(BuildContext context) {
    // Resolve potentially stale iOS sandbox path
    final raw = imagePath;
    final resolvedPath = ImageService.instance.resolveStoredPath(raw);
    final String networkPath = resolvedPath != null &&
            (resolvedPath.startsWith('http://') ||
                resolvedPath.startsWith('https://') ||
                resolvedPath.startsWith('blob:') ||
                resolvedPath.startsWith('data:'))
        ? resolvedPath
        : (raw != null &&
                (raw.startsWith('http://') ||
                    raw.startsWith('https://') ||
                    raw.startsWith('blob:') ||
                    raw.startsWith('data:'))
            ? raw
            : '');
    final file = !kIsWeb &&
            resolvedPath != null &&
            !resolvedPath.startsWith('http://') &&
            !resolvedPath.startsWith('https://')
        ? File(resolvedPath)
        : null;
    final hasImage = file != null && file.existsSync();
    final hasNetworkImage = networkPath.isNotEmpty;
    // OPFS-stored images on web (e.g. a channel avatar received over the
    // network) — read bytes and render via Image.memory.
    final String? webStoredPath = kIsWeb && networkPath.isEmpty
        ? ((resolvedPath != null && isWebStoredFile(resolvedPath))
            ? resolvedPath
            : (raw != null && isWebStoredFile(raw) ? raw : null))
        : null;

    // If story ring is shown, shrink the avatar by 6px so the ring fits within size
    final ringWidth = hasStory ? 3.0 : 0.0;
    final gap = hasStory ? 2.0 : 0.0;
    // Guard against negative/zero size to prevent NaN in CoreGraphics
    final innerSize = math.max(size - (ringWidth + gap) * 2, 1.0);

    // Декодируем аватар в РАЗМЕР ОТОБРАЖЕНИЯ, а не в исходное разрешение фото.
    // Без этого фото 1000×1000 декодируется целиком ради кружка 52px → тяжёлый
    // decode при заезде строки в список и раздутый image-cache (GC-фризы) —
    // главная причина лагов при скролле списка чатов.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // Quantise the decode size: while the profile header animates, innerSize
    // changes every frame, and a fresh cacheWidth per frame re-decodes the
    // image each time — that was the flicker and the jank. Rounding to 64px
    // steps keeps one cached decode for the whole animation.
    final rawSide = innerSize * dpr;
    final decodeSide = ((rawSide / 64).ceil() * 64).clamp(1, 4096);

    final radius = BorderRadius.circular(cornerRadius ?? innerSize / 2);
    Widget avatar = Container(
      width: innerSize,
      height: innerSize,
      decoration: BoxDecoration(
        color: Color(color),
        borderRadius: radius,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: hasImage
            ? Image.file(
                file,
                width: innerSize,
                height: innerSize,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: decodeSide,
                cacheHeight: decodeSide,
                errorBuilder: (_, __, ___) => Center(
                  child: _buildEmojiOrInitials(innerSize),
                ),
              )
            : hasNetworkImage
                ? Image.network(
                    networkPath,
                    width: innerSize,
                    height: innerSize,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    cacheWidth: decodeSide,
                    cacheHeight: decodeSide,
                    errorBuilder: (_, __, ___) => Center(
                      child: _buildEmojiOrInitials(innerSize),
                    ),
                  )
                : webStoredPath != null
                    ? FutureBuilder<Uint8List?>(
                        future: readWebStoredFile(webStoredPath),
                        builder: (_, snap) {
                          final b = snap.data;
                          if (b == null || b.isEmpty) {
                            return Center(
                                child: _buildEmojiOrInitials(innerSize));
                          }
                          return Image.memory(
                            b,
                            width: innerSize,
                            height: innerSize,
                            fit: BoxFit.cover,
                            cacheWidth: decodeSide,
                            cacheHeight: decodeSide,
                            errorBuilder: (_, __, ___) => Center(
                              child: _buildEmojiOrInitials(innerSize),
                            ),
                          );
                        },
                      )
                    : Center(
                        child: _buildEmojiOrInitials(innerSize),
                      ),
      ),
    );

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (hasStory)
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: hasUnviewedStory
                    ? const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFFE91E63),
                          Color(0xFFFF9800),
                          Color(0xFFFFEB3B)
                        ],
                      )
                    : LinearGradient(
                        colors: [Colors.grey.shade500, Colors.grey.shade700],
                      ),
              ),
            ),
          if (hasStory)
            Container(
              width: innerSize + gap * 2,
              height: innerSize + gap * 2,
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                shape: BoxShape.circle,
              ),
            ),
          avatar,
          if (isOnline)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: size * 0.46,
                height: size * 0.28,
                padding: EdgeInsets.symmetric(horizontal: size * 0.03),
                decoration: BoxDecoration(
                  color: AppSettings.instance.onlineStatusColor,
                  borderRadius: BorderRadius.circular(size * 0.2),
                  border: Border.all(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    width: 2,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: _statusIcons(size),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmojiOrInitials(double innerSize) {
    if (emoji.isNotEmpty) {
      final m = _shortcodeRe.firstMatch(emoji.trim());
      if (m != null) {
        final provider =
            EmojiPackService.instance.emojiImageProvider(m.group(1)!);
        if (provider != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(innerSize * 0.16),
            child: Image(
              image: provider,
              width: innerSize * 0.72,
              height: innerSize * 0.72,
              fit: BoxFit.cover,
            ),
          );
        }
      }
      return Text(emoji, style: TextStyle(fontSize: innerSize * 0.46));
    }
    return Text(
      initials.isNotEmpty ? initials : '?',
      style: TextStyle(
        color: Colors.white,
        fontSize: innerSize * 0.38,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    );
  }

  List<Widget> _statusIcons(double avatarSize) {
    final iconSize = avatarSize * 0.12;
    final icons = <IconData>[];
    for (final t in onlineTransports) {
      switch (t) {
        case AvatarPresenceTransport.bluetooth:
          icons.add(Icons.bluetooth);
          break;
        case AvatarPresenceTransport.internet:
          icons.add(Icons.public);
          break;
        case AvatarPresenceTransport.wifiDirect:
          icons.add(Icons.wifi);
          break;
      }
    }
    final selected = icons.take(2).toList();
    if (selected.isEmpty) {
      selected.add(Icons.circle);
    }
    final out = <Widget>[];
    for (var i = 0; i < selected.length; i++) {
      out.add(Icon(selected[i], size: iconSize, color: Colors.white));
      if (i != selected.length - 1) {
        out.add(SizedBox(width: avatarSize * 0.012));
      }
    }
    return out;
  }
}

// ── Выбор эмодзи (Unicode + мои кастомные) ──

class AvatarEmojiPicker extends StatefulWidget {
  final String selected;
  final void Function(String emoji) onSelected;
  final bool showStickersTab;
  final void Function(String path)? onStickerPicked;
  final void Function(String url)? onGifPicked;

  const AvatarEmojiPicker({
    super.key,
    required this.selected,
    required this.onSelected,
    this.showStickersTab = false,
    this.onStickerPicked,
    this.onGifPicked,
  });

  @override
  State<AvatarEmojiPicker> createState() => _AvatarEmojiPickerState();
}

class _AvatarEmojiPickerState extends State<AvatarEmojiPicker> {
  List<File> _stickerFiles = [];
  List<StickerPack> _stickerPacks = [];
  String? _filterStickerPackId;
  List<String> _gifUrls = [];
  bool _loadingGifs = false;

  // Emoji packs for "Мои эмодзи" section

  @override
  void initState() {
    super.initState();
    if (widget.showStickersTab) {
      StickerCollectionService.instance.version.addListener(_loadStickers);
      _loadStickers();
      _loadGifs();
    }
  }

  @override
  void dispose() {
    if (widget.showStickersTab) {
      StickerCollectionService.instance.version.removeListener(_loadStickers);
    }
    super.dispose();
  }

  Future<void> _loadStickers() async {
    await StickerCollectionService.instance.init();
    final packs = await StickerCollectionService.instance.loadPacks();
    final files = await StickerCollectionService.instance
        .stickerFilesForPack(_filterStickerPackId);
    if (mounted) {
      setState(() {
        _stickerPacks = packs;
        _stickerFiles = files;
      });
    }
  }

  Future<void> _loadGifs() async {
    setState(() => _loadingGifs = true);
    const gifs = [
      'https://media.giphy.com/media/JIX9t2j0ZTN9S/giphy.gif',
      'https://media.giphy.com/media/l0HlHFRbmaZtBRhXG/giphy.gif',
      'https://media.giphy.com/media/3o7TKoWXm3okO1kgHC/giphy.gif',
      'https://media.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif',
      'https://media.giphy.com/media/xT0xeuOy2Fcl9vDGiA/giphy.gif',
      'https://media.giphy.com/media/26u4cqiYI30juCOGY/giphy.gif',
      'https://media.giphy.com/media/3o7aD2saalBwwftBIY/giphy.gif',
      'https://media.giphy.com/media/l1KVaj5UcbHwrBMqI/giphy.gif',
    ];
    if (mounted) {
      setState(() {
        _gifUrls = gifs;
        _loadingGifs = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (widget.showStickersTab) {
      // Show tabs when stickers tab is enabled (for sticker picker)
      return DefaultTabController(
        length: 3,
        child: SizedBox(
          height: 320,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TabBar(
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicator: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  labelColor: cs.primary,
                  unselectedLabelColor: cs.onSurfaceVariant,
                  dividerColor: Colors.transparent,
                  tabs: const [
                    Tab(text: 'Эмодзи'),
                    Tab(text: 'Стикеры'),
                    Tab(text: 'Гиф'),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: TabBarView(
                  children: [
                    UnifiedEmojiPicker(onSelected: widget.onSelected),
                    _StickerGrid(
                      stickerFiles: _stickerFiles,
                      stickerPacks: _stickerPacks,
                      filterPackId: _filterStickerPackId,
                      onPackSelected: (packId) {
                        setState(() => _filterStickerPackId = packId);
                        unawaited(_loadStickers());
                      },
                      onStickerPicked: widget.onStickerPicked ??
                          (path) {
                            // Default: stickers can't be inserted as text
                            debugPrint('[RLINK][Emoji] Sticker picked: $path');
                          },
                    ),
                    _GifGrid(
                      gifUrls: _gifUrls,
                      loading: _loadingGifs,
                      onGifPicked: widget.onGifPicked ??
                          (url) {
                            // Default: log GIF pick
                            debugPrint('[RLINK][Emoji] GIF picked: $url');
                          },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Show only the unified picker (packs + official in one row).
    return SizedBox(
      height: 320,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: UnifiedEmojiPicker(onSelected: widget.onSelected),
      ),
    );
  }
}

class _StickerGrid extends StatelessWidget {
  static const _defaultStickerAssetPrefix = 'assets/sticker_packs/default/';
  static const _defaultStickerAssetNames = <String>[
    'Angry.png',
    'Best.png',
    'Happy.png',
    'Jump.png',
    'LapTop.png',
    'Like.png',
    'Love.png',
    'MAX.png',
    'Sad.png',
    'Scary.png',
    'Wery scary.png',
    'Woah!.png',
  ];

  final List<File> stickerFiles;
  final List<StickerPack> stickerPacks;
  final String? filterPackId;
  final void Function(String? packId) onPackSelected;
  final void Function(String path) onStickerPicked;

  const _StickerGrid({
    required this.stickerFiles,
    required this.stickerPacks,
    required this.filterPackId,
    required this.onPackSelected,
    required this.onStickerPicked,
  });

  @override
  Widget build(BuildContext context) {
    final showDefaultWebStickers = kIsWeb && stickerFiles.isEmpty;
    return Column(
      children: [
        if (stickerPacks.isNotEmpty)
          SizedBox(
            height: 70,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: stickerPacks.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  final isSelected = filterPackId == null;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: GestureDetector(
                      onTap: () => onPackSelected(null),
                      child: Column(
                        children: [
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? Theme.of(context)
                                      .colorScheme
                                      .primaryContainer
                                  : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                              border: isSelected
                                  ? Border.all(
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                      width: 2)
                                  : null,
                            ),
                            child: const Icon(Icons.apps, size: 28),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Все',
                            style: TextStyle(
                              fontSize: 11,
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                final packIndex = index - 1;
                final pack = stickerPacks[packIndex];
                final isSelected = filterPackId == pack.id;
                final firstStickerRel = pack.stickerRelPaths.isNotEmpty
                    ? pack.stickerRelPaths.first
                    : null;

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: GestureDetector(
                    onTap: () => onPackSelected(pack.id),
                    child: Column(
                      children: [
                        Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Theme.of(context).colorScheme.primaryContainer
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                            border: isSelected
                                ? Border.all(
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                    width: 2)
                                : null,
                          ),
                          child: firstStickerRel != null
                              ? FutureBuilder<File?>(
                                  future: _getStickerFile(firstStickerRel),
                                  builder: (context, snapshot) {
                                    if (!snapshot.hasData ||
                                        snapshot.data == null) {
                                      return const Icon(Icons.sticky_note_2,
                                          size: 24);
                                    }
                                    return ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: Image.file(
                                        snapshot.data!,
                                        fit: BoxFit.cover,
                                      ),
                                    );
                                  },
                                )
                              : const Icon(Icons.sticky_note_2, size: 24),
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          width: 50,
                          child: Text(
                            pack.title,
                            style: TextStyle(
                              fontSize: 11,
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        Expanded(
          child: showDefaultWebStickers
              ? GridView.builder(
                  padding: const EdgeInsets.all(6),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 6,
                  ),
                  itemCount: _defaultStickerAssetNames.length,
                  itemBuilder: (context, index) {
                    final asset =
                        '$_defaultStickerAssetPrefix${_defaultStickerAssetNames[index]}';
                    return GestureDetector(
                      onTap: () => onStickerPicked(asset),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.asset(asset, fit: BoxFit.contain),
                      ),
                    );
                  },
                )
              : stickerFiles.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'В этом наборе пока нет стикеров',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(6),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        crossAxisSpacing: 6,
                        mainAxisSpacing: 6,
                      ),
                      itemCount: stickerFiles.length,
                      itemBuilder: (context, index) {
                        final file = stickerFiles[index];
                        return GestureDetector(
                          onTap: () => onStickerPicked(file.path),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              file,
                              fit: BoxFit.cover,
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Future<File?> _getStickerFile(String relPath) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final absPath = p.join(docs.path, relPath);
      final file = File(absPath);
      if (await file.exists()) {
        return file;
      }
      return null;
    } catch (e) {
      return null;
    }
  }
}

class _GifGrid extends StatelessWidget {
  final List<String> gifUrls;
  final bool loading;
  final void Function(String url) onGifPicked;

  const _GifGrid({
    required this.gifUrls,
    required this.loading,
    required this.onGifPicked,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (loading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (gifUrls.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Гифки недоступны',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(6),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: gifUrls.length,
      itemBuilder: (context, index) {
        final url = gifUrls[index];
        return GestureDetector(
          onTap: () => onGifPicked(url),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              url,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return Center(
                  child: CircularProgressIndicator(
                    value: loadingProgress.expectedTotalBytes != null
                        ? loadingProgress.cumulativeBytesLoaded /
                            loadingProgress.expectedTotalBytes!
                        : null,
                  ),
                );
              },
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  color: cs.surfaceContainerHighest,
                  child: const Icon(Icons.broken_image),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

// ── Выбор цвета фона аватара ────────────────────────────────────

class AvatarColorPicker extends StatelessWidget {
  final int selected;
  final void Function(int color) onSelected;

  const AvatarColorPicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  static const _colors = [
    0xFF5C6BC0,
    0xFF26A69A,
    0xFFEF5350,
    0xFFAB47BC,
    0xFF42A5F5,
    0xFF66BB6A,
    0xFFFF7043,
    0xFFEC407A,
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: _colors.map((c) {
        final isSelected = c == selected;
        return GestureDetector(
          onTap: () => onSelected(c),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Color(c),
              shape: BoxShape.circle,
              border:
                  isSelected ? Border.all(color: Colors.white, width: 3) : null,
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                          color: Color(c).withValues(alpha: 0.6), blurRadius: 8)
                    ]
                  : null,
            ),
          ),
        );
      }).toList(),
    );
  }
}
