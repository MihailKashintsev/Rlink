import 'dart:io';
import 'dart:math' as math;
import 'dart:async';
import 'dart:typed_data';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' as epf;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/sticker_pack.dart';
import '../../utils/web_file_store.dart';
import '../../models/emoji_pack.dart';
import '../../services/app_settings.dart';
import '../../services/emoji_pack_service.dart';
import '../../services/image_service.dart';
import '../../services/runtime_platform.dart';
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

    Widget avatar = Container(
      width: innerSize,
      height: innerSize,
      decoration: BoxDecoration(
        color: Color(color),
        shape: BoxShape.circle,
      ),
      child: ClipOval(
        child: hasImage
            ? Image.file(
                file,
                width: innerSize,
                height: innerSize,
                fit: BoxFit.cover,
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
  List<EmojiPack> _emojiPacks = [];
  bool _loadingEmojiPacks = false;
  String? _docsPath;

  @override
  void initState() {
    super.initState();
    if (widget.showStickersTab) {
      StickerCollectionService.instance.version.addListener(_loadStickers);
      _loadStickers();
      _loadGifs();
    }
    _initEmojiPacks();
  }

  Future<void> _initEmojiPacks() async {
    // getApplicationDocumentsDirectory() THROWS on web — guard it, otherwise
    // _loadEmojiPacks() never runs and the "Мои эмодзи" section never appears.
    if (!kIsWeb) {
      try {
        final docs = await getApplicationDocumentsDirectory();
        if (mounted) setState(() => _docsPath = docs.path);
      } catch (_) {}
    }
    _loadEmojiPacks();
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

  Future<void> _loadEmojiPacks() async {
    setState(() => _loadingEmojiPacks = true);
    try {
      await EmojiPackService.instance.warmIndex();
      final packs = await EmojiPackService.instance.loadPacks();
      if (mounted) {
        setState(() {
          _emojiPacks = packs;
          _loadingEmojiPacks = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingEmojiPacks = false);
      }
    }
  }

  void _showEmojiPackPicker(BuildContext context, EmojiPack pack) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          builder: (context, scrollController) {
            return Column(
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    pack.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Expanded(
                  child: GridView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.all(16),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 5,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: pack.emojis.length,
                    itemBuilder: (context, index) {
                      final emoji = pack.emojis[index];
                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          // Insert the actual emoji character (shortcode format requires recipient to have pack)
                          // For now, insert as text - the recipient needs the emoji pack installed
                          widget.onSelected(':${emoji.shortcode}:');
                        },
                        child: Builder(
                          builder: (context) {
                            final provider = EmojiPackService.instance
                                .emojiImageProvider(emoji.shortcode);
                            if (provider == null) return const SizedBox();
                            return Image(image: provider, fit: BoxFit.contain);
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final useNoto =
        RuntimePlatform.isAndroid && AppSettings.instance.useIosStyleEmoji;

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
                    Column(
                      children: [
                        // "Мои эмодзи" section
                        if (_loadingEmojiPacks)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(
                              child: CircularProgressIndicator(),
                            ),
                          )
                        else if (_emojiPacks.isNotEmpty)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: 8,
                                  right: 8,
                                  bottom: 8,
                                ),
                                child: Text(
                                  'Мои эмодзи',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: cs.onSurfaceVariant,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              SizedBox(
                                height: 60,
                                child: ListView.builder(
                                  scrollDirection: Axis.horizontal,
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8),
                                  itemCount: _emojiPacks.length,
                                  itemBuilder: (context, index) {
                                    final pack = _emojiPacks[index];
                                    return GestureDetector(
                                      onTap: () {
                                        // Show emoji picker for this pack
                                        _showEmojiPackPicker(context, pack);
                                      },
                                      child: Container(
                                        width: 50,
                                        margin: const EdgeInsets.only(right: 8),
                                        decoration: BoxDecoration(
                                          color: cs.surfaceContainerHighest
                                              .withValues(alpha: 0.5),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Builder(
                                              builder: (_) {
                                                final provider = pack
                                                        .emojis.isNotEmpty
                                                    ? EmojiPackService.instance
                                                        .emojiImageProvider(pack
                                                            .emojis[0]
                                                            .shortcode)
                                                    : null;
                                                if (provider == null) {
                                                  return Icon(
                                                    Icons
                                                        .emoji_emotions_outlined,
                                                    size: 24,
                                                    color: cs.onSurfaceVariant,
                                                  );
                                                }
                                                return Image(
                                                  image: provider,
                                                  width: 32,
                                                  height: 32,
                                                  fit: BoxFit.contain,
                                                );
                                              },
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              pack.name,
                                              style: TextStyle(
                                                fontSize: 9,
                                                color: cs.onSurfaceVariant,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const Divider(height: 16),
                            ],
                          ),
                        // Standard emoji picker
                        SizedBox(
                          height: _emojiPacks.isNotEmpty ? 200 : 280,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: epf.EmojiPicker(
                              onEmojiSelected: (_, emoji) =>
                                  widget.onSelected(emoji.emoji),
                              config: epf.Config(
                                height: _emojiPacks.isNotEmpty ? 200 : 280,
                                checkPlatformCompatibility: !useNoto,
                                emojiTextStyle: useNoto
                                    ? GoogleFonts.notoColorEmoji(fontSize: 26)
                                    : null,
                                emojiViewConfig: epf.EmojiViewConfig(
                                  backgroundColor: cs.surfaceContainerHighest
                                      .withValues(alpha: 0.5),
                                  columns: 8,
                                  emojiSizeMax: 26,
                                ),
                                categoryViewConfig: epf.CategoryViewConfig(
                                  backgroundColor: cs.surfaceContainerHighest
                                      .withValues(alpha: 0.5),
                                  iconColorSelected: cs.primary,
                                  indicatorColor: cs.primary,
                                  iconColor: cs.onSurfaceVariant,
                                ),
                                bottomActionBarConfig:
                                    epf.BottomActionBarConfig(
                                  backgroundColor: cs.surfaceContainerHighest
                                      .withValues(alpha: 0.5),
                                  buttonIconColor: cs.onSurfaceVariant,
                                ),
                                searchViewConfig: epf.SearchViewConfig(
                                  backgroundColor: cs.surfaceContainerHighest
                                      .withValues(alpha: 0.5),
                                  buttonIconColor: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
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

    // Show only emoji picker without tabs
    return SizedBox(
      height: 320,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: epf.EmojiPicker(
          onEmojiSelected: (_, emoji) => widget.onSelected(emoji.emoji),
          config: epf.Config(
            height: 320,
            checkPlatformCompatibility: !useNoto,
            emojiTextStyle:
                useNoto ? GoogleFonts.notoColorEmoji(fontSize: 26) : null,
            emojiViewConfig: epf.EmojiViewConfig(
              backgroundColor:
                  cs.surfaceContainerHighest.withValues(alpha: 0.5),
              columns: 8,
              emojiSizeMax: 26,
            ),
            categoryViewConfig: epf.CategoryViewConfig(
              backgroundColor:
                  cs.surfaceContainerHighest.withValues(alpha: 0.5),
              iconColorSelected: cs.primary,
              indicatorColor: cs.primary,
              iconColor: cs.onSurfaceVariant,
            ),
            bottomActionBarConfig: epf.BottomActionBarConfig(
              backgroundColor:
                  cs.surfaceContainerHighest.withValues(alpha: 0.5),
              buttonIconColor: cs.onSurfaceVariant,
            ),
            searchViewConfig: epf.SearchViewConfig(
              backgroundColor:
                  cs.surfaceContainerHighest.withValues(alpha: 0.5),
              buttonIconColor: cs.onSurfaceVariant,
            ),
          ),
        ),
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
