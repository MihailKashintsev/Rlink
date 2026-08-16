import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import '../../l10n/app_l10n.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/sticker_pack.dart';
import '../../services/runtime_platform.dart';
import '../../services/sticker_collection_service.dart';
import '../../utils/web_object_url.dart';
import '../../services/app_settings.dart';
import 'desktop_image_picker.dart';
import 'sticker_crop_screen.dart';

const _kRecentFilesPrefKey = 'media_gallery_recent_files_v1';
const _kMaxRecentFiles = 24;

bool get _useNativePhotoGrid {
  if (kIsWeb) return false;
  // User asked for the OS picker in Settings → Галерея.
  if (AppSettings.instance.useSystemGallery) return false;
  // PhotoManager doesn't work well on macOS, use desktop picker instead
  return RuntimePlatform.isAndroid || RuntimePlatform.isIos;
}

bool _isGifMime(String? m) => m != null && m.toLowerCase().contains('gif');

Future<void> _rememberFilePath(String path) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kRecentFilesPrefKey);
    var list = <String>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        list = (jsonDecode(raw) as List).cast<String>();
      } catch (_) {}
    }
    list = [path, ...list.where((p) => p != path)];
    if (list.length > _kMaxRecentFiles) {
      list = list.sublist(0, _kMaxRecentFiles);
    }
    await prefs.setString(_kRecentFilesPrefKey, jsonEncode(list));
  } catch (_) {}
}

Future<List<String>> _loadRecentFilePaths() async {
  if (kIsWeb) return [];
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kRecentFilesPrefKey);
    if (raw == null || raw.isEmpty) return [];
    final list = (jsonDecode(raw) as List).cast<String>();
    return list.where((p) => File(p).existsSync()).toList();
  } catch (_) {
    return [];
  }
}

/// Tabbed gallery sheet for full gallery view (fallback)
Future<void> showTabbedGallerySheet(
  BuildContext context, {
  required Future<void> Function(String filePath) onPhotoPath,
  required Future<void> Function(String filePath) onGifPath,
  required Future<void> Function(String filePath) onVideoPath,
  required Future<void> Function(Uint8List croppedBytes) onStickerCropped,
  required Future<void> Function(String stickerLibraryFilePath)
      onStickerFromLibrary,
  required Future<void> Function(String filePath) onFilePath,
  required VoidCallback? onOpenEmojiInsert,
  Future<void> Function()? onLocation,
  Future<void> Function()? onTodo,
  Future<void> Function()? onPoll,
  Future<void> Function()? onCalendarEvent,
}) {
  final hasExtraMenu = onLocation != null ||
      onTodo != null ||
      onPoll != null ||
      onCalendarEvent != null;
  final tabs = <Tab>[
    const Tab(text: 'Фото'),
    const Tab(text: 'Видео'),
    const Tab(text: 'Файлы'),
    if (hasExtraMenu) const Tab(text: 'Меню'),
  ];
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.45,
        maxChildSize: 0.95,
        builder: (context, _) {
          return DefaultTabController(
            length: tabs.length,
            child: Column(
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
                TabBar(
                  isScrollable: true,
                  tabs: tabs,
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _GalleryTab(
                        mode: _GalleryMode.photo,
                        onPhotoPath: onPhotoPath,
                        onGifPath: onGifPath,
                        onVideoPath: onVideoPath,
                        sheetContext: ctx,
                      ),
                      _GalleryTab(
                        mode: _GalleryMode.video,
                        onPhotoPath: onPhotoPath,
                        onGifPath: onGifPath,
                        onVideoPath: onVideoPath,
                        sheetContext: ctx,
                      ),
                      _FilesGalleryTab(
                        sheetContext: ctx,
                        onFilePath: onFilePath,
                      ),
                      if (hasExtraMenu)
                        _ExtraActionsMenuTab(
                          sheetContext: ctx,
                          onLocation: onLocation,
                          onTodo: onTodo,
                          onPoll: onPoll,
                          onCalendarEvent: onCalendarEvent,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

/// Telegram-style media gallery with horizontal scroll and categories
Future<void> showMediaGallerySendSheet(
  BuildContext context, {
  required Future<void> Function(String filePath) onPhotoPath,
  required Future<void> Function(String filePath) onGifPath,
  required Future<void> Function(String filePath) onVideoPath,
  required Future<void> Function(Uint8List croppedBytes) onStickerCropped,
  required Future<void> Function(String stickerLibraryFilePath)
      onStickerFromLibrary,
  required Future<void> Function(String filePath) onFilePath,
  required VoidCallback? onOpenEmojiInsert,
  Future<void> Function()? onLocation,
  Future<void> Function()? onTodo,
  Future<void> Function()? onPoll,
  Future<void> Function()? onCalendarEvent,
  bool isEmojiBot = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _TelegramMediaGallerySheet(
      sheetContext: ctx,
      onPhotoPath: onPhotoPath,
      onGifPath: onGifPath,
      onVideoPath: onVideoPath,
      onStickerCropped: onStickerCropped,
      onStickerFromLibrary: onStickerFromLibrary,
      onFilePath: onFilePath,
      onOpenEmojiInsert: onOpenEmojiInsert,
      onLocation: onLocation,
      onTodo: onTodo,
      onPoll: onPoll,
      onCalendarEvent: onCalendarEvent,
      isEmojiBot: isEmojiBot,
    ),
  );
}

class _TelegramMediaGallerySheet extends StatefulWidget {
  final BuildContext sheetContext;
  final Future<void> Function(String filePath) onPhotoPath;
  final Future<void> Function(String filePath) onGifPath;
  final Future<void> Function(String filePath) onVideoPath;
  final Future<void> Function(Uint8List croppedBytes) onStickerCropped;
  final Future<void> Function(String stickerLibraryFilePath)
      onStickerFromLibrary;
  final Future<void> Function(String filePath) onFilePath;
  final VoidCallback? onOpenEmojiInsert;
  final Future<void> Function()? onLocation;
  final Future<void> Function()? onTodo;
  final Future<void> Function()? onPoll;
  final Future<void> Function()? onCalendarEvent;
  final bool isEmojiBot;

  const _TelegramMediaGallerySheet({
    super.key,
    required this.sheetContext,
    required this.onPhotoPath,
    required this.onGifPath,
    required this.onVideoPath,
    required this.onStickerCropped,
    required this.onStickerFromLibrary,
    required this.onFilePath,
    required this.onOpenEmojiInsert,
    required this.onLocation,
    required this.onTodo,
    required this.onPoll,
    required this.onCalendarEvent,
    required this.isEmojiBot,
  });

  @override
  State<_TelegramMediaGallerySheet> createState() =>
      _TelegramMediaGallerySheetState();
}

class _TelegramMediaGallerySheetState extends State<_TelegramMediaGallerySheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final fixedHeight = keyboardHeight > 0 ? keyboardHeight : 400.0;

    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Container(
        color: Colors.black.withOpacity(0.4),
        child: Container(
          height: fixedHeight,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Drag handle
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 8, bottom: 8),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Content area
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _PhotoTab(onPhotoPath: widget.onPhotoPath),
                    _VideoTab(onVideoPath: widget.onVideoPath),
                    _GalleryFilesTab(onFilePath: widget.onFilePath),
                    _OtherTab(
                      onLocation: widget.onLocation,
                      onTodo: widget.onTodo,
                      onPoll: widget.onPoll,
                      onCalendarEvent: widget.onCalendarEvent,
                    ),
                  ],
                ),
              ),
              // Bottom tab selector
              _GalleryBottomTabSelector(
                tabController: _tabController,
                onOpenEmojiInsert: widget.onOpenEmojiInsert,
                isEmojiBot: widget.isEmojiBot,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoTab extends StatelessWidget {
  final Future<void> Function(String filePath) onPhotoPath;

  const _PhotoTab({super.key, required this.onPhotoPath});

  @override
  Widget build(BuildContext context) {
    return _GalleryTab(
      mode: _GalleryMode.photo,
      onPhotoPath: (path) async => await onPhotoPath(path),
      onGifPath: (_) async {},
      onVideoPath: (_) async {},
      sheetContext: context,
    );
  }
}

class _VideoTab extends StatelessWidget {
  final Future<void> Function(String filePath) onVideoPath;

  const _VideoTab({super.key, required this.onVideoPath});

  @override
  Widget build(BuildContext context) {
    return _GalleryTab(
      mode: _GalleryMode.video,
      onPhotoPath: (_) async {},
      onGifPath: (_) async {},
      onVideoPath: (path) async => await onVideoPath(path),
      sheetContext: context,
    );
  }
}

class _GalleryFilesTab extends StatelessWidget {
  final Future<void> Function(String filePath) onFilePath;

  const _GalleryFilesTab({super.key, required this.onFilePath});

  @override
  Widget build(BuildContext context) {
    return _FilesGalleryTab(
      sheetContext: context,
      onFilePath: onFilePath,
    );
  }
}

class _OtherTab extends StatelessWidget {
  final Future<void> Function()? onLocation;
  final Future<void> Function()? onTodo;
  final Future<void> Function()? onPoll;
  final Future<void> Function()? onCalendarEvent;

  const _OtherTab({
    super.key,
    this.onLocation,
    this.onTodo,
    this.onPoll,
    this.onCalendarEvent,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      child: GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 1.5,
        children: [
          if (onLocation != null)
            _GridActionButton(
              icon: Icons.location_on,
              label: 'Локация',
              color: cs.primary,
              onTap: () {
                Navigator.of(context).pop();
                unawaited(onLocation!());
              },
            ),
          if (onTodo != null)
            _GridActionButton(
              icon: Icons.checklist_rtl,
              label: 'Задачи',
              color: cs.tertiary,
              onTap: () {
                Navigator.of(context).pop();
                unawaited(onTodo!());
              },
            ),
          if (onPoll != null)
            _GridActionButton(
              icon: Icons.poll,
              label: 'Опрос',
              color: cs.secondary,
              onTap: () {
                Navigator.of(context).pop();
                unawaited(onPoll!());
              },
            ),
          if (onCalendarEvent != null)
            _GridActionButton(
              icon: Icons.event,
              label: 'Событие',
              color: cs.error,
              onTap: () {
                Navigator.of(context).pop();
                unawaited(onCalendarEvent!());
              },
            ),
        ],
      ),
    );
  }
}

class _GridActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _GridActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 32, color: color),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GalleryBottomTabSelector extends StatelessWidget {
  final TabController tabController;
  final VoidCallback? onOpenEmojiInsert;
  final bool isEmojiBot;

  const _GalleryBottomTabSelector({
    super.key,
    required this.tabController,
    required this.onOpenEmojiInsert,
    required this.isEmojiBot,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TabBar(
              controller: tabController,
              tabs: [
                const Tab(icon: Icon(Icons.photo_library)),
                const Tab(icon: Icon(Icons.videocam)),
                const Tab(icon: Icon(Icons.insert_drive_file)),
                const Tab(icon: Icon(Icons.more_horiz)),
              ],
              indicatorSize: TabBarIndicatorSize.label,
            ),
          ),
        ],
      ),
    );
  }
}

class _TelegramAttachmentSheet extends StatefulWidget {
  final BuildContext sheetContext;
  final Future<void> Function(String filePath) onPhotoPath;
  final Future<void> Function(String filePath) onGifPath;
  final Future<void> Function(String filePath) onVideoPath;
  final Future<void> Function(Uint8List croppedBytes) onStickerCropped;
  final Future<void> Function(String stickerLibraryFilePath)
      onStickerFromLibrary;
  final Future<void> Function(String filePath) onFilePath;
  final VoidCallback? onOpenEmojiInsert;
  final VoidCallback? onOpenCamera;
  final Future<void> Function()? onLocation;
  final Future<void> Function()? onTodo;
  final Future<void> Function()? onPoll;
  final Future<void> Function()? onCalendarEvent;
  final Future<void> Function()? onContact;

  const _TelegramAttachmentSheet({
    super.key,
    required this.sheetContext,
    required this.onPhotoPath,
    required this.onGifPath,
    required this.onVideoPath,
    required this.onStickerCropped,
    required this.onStickerFromLibrary,
    required this.onFilePath,
    required this.onOpenEmojiInsert,
    required this.onOpenCamera,
    required this.onLocation,
    required this.onTodo,
    required this.onPoll,
    required this.onCalendarEvent,
    required this.onContact,
  });

  @override
  State<_TelegramAttachmentSheet> createState() =>
      _TelegramAttachmentSheetState();
}

class _TelegramAttachmentSheetState extends State<_TelegramAttachmentSheet> {
  final Set<int> _selectedIndices = {};

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Container(
        color: Colors.black.withOpacity(0.4),
        child: DraggableScrollableSheet(
          initialChildSize: 0.4,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          snap: true,
          snapSizes: const [0.4, 0.95],
          builder: (context, scrollController) {
            return GestureDetector(
              onTap: () {},
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                ),
                child: Column(
                  children: [
                    // Drag handle
                    Center(
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 12),
                        width: 32,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant
                              .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    // Gallery preview grid
                    Expanded(
                      child: _GalleryPreviewGrid(
                        scrollController: scrollController,
                        onPhotoPath: widget.onPhotoPath,
                        onGifPath: widget.onGifPath,
                        onVideoPath: widget.onVideoPath,
                        onOpenCamera: widget.onOpenCamera,
                        selectedIndices: _selectedIndices,
                        onSelectionChanged: (indices) {
                          setState(() {
                            _selectedIndices.clear();
                            _selectedIndices.addAll(indices);
                          });
                        },
                      ),
                    ),
                    // Send button when items are selected
                    if (_selectedIndices.isNotEmpty)
                      _SendButton(
                        count: _selectedIndices.length,
                        onSend: () => _sendSelected(),
                      ),
                    // Action bar
                    _ActionBar(
                      onOpenGallery: () => _openFullGallery(context),
                      onOpenFile: () => _openFilePicker(context),
                      onLocation: widget.onLocation,
                      onTodo: widget.onTodo,
                      onPoll: widget.onPoll,
                      onCalendarEvent: widget.onCalendarEvent,
                      onContact: widget.onContact,
                      onOpenEmojiInsert: widget.onOpenEmojiInsert,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _sendSelected() {
    Navigator.of(context).pop();
    // Send selected items
  }

  void _openFullGallery(BuildContext context) {
    // Do nothing - keep using the new Telegram-style interface
    // The horizontal scroll and action bar are already shown
  }

  void _openFilePicker(BuildContext context) async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false,
    );
    final path = r?.files.single.path;
    if (path == null || !mounted) return;
    await _rememberFilePath(path);
    Navigator.of(context).pop();
    await widget.onFilePath(path);
  }
}

class _SendButton extends StatelessWidget {
  final int count;
  final VoidCallback onSend;

  const _SendButton({
    super.key,
    required this.count,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () {},
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: onSend,
            icon: const Icon(Icons.send),
            label: Text('Отправить $count'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _GalleryPreviewGrid extends StatefulWidget {
  final ScrollController scrollController;
  final Future<void> Function(String filePath) onPhotoPath;
  final Future<void> Function(String filePath) onGifPath;
  final Future<void> Function(String filePath) onVideoPath;
  final VoidCallback? onOpenCamera;
  final Set<int> selectedIndices;
  final Function(Set<int>) onSelectionChanged;

  const _GalleryPreviewGrid({
    super.key,
    required this.scrollController,
    required this.onPhotoPath,
    required this.onGifPath,
    required this.onVideoPath,
    required this.onOpenCamera,
    required this.selectedIndices,
    required this.onSelectionChanged,
  });

  @override
  State<_GalleryPreviewGrid> createState() => _GalleryPreviewGridState();
}

class _GalleryPreviewGridState extends State<_GalleryPreviewGrid> {
  List<AssetEntity>? _assets;
  // Desktop has no photo library to enumerate — show what was sent recently
  // instead of an empty sheet with a "pick a file" button.
  List<String> _recentFiles = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (_useNativePhotoGrid) {
      _loadRecentMedia();
    } else {
      _loadRecentFiles();
    }
  }

  Future<void> _loadRecentFiles() async {
    final list = await _loadRecentFilePathsSafe();
    if (!mounted) return;
    setState(() {
      _recentFiles = list;
      _loading = false;
    });
  }

  Future<List<String>> _loadRecentFilePathsSafe() async {
    try {
      return await _loadRecentFilePaths();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _loadRecentMedia() async {
    try {
      final state = await PhotoManager.requestPermissionExtend();
      if (!state.hasAccess) {
        setState(() {
          _loading = false;
          _assets = [];
        });
        return;
      }

      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        hasAll: true,
        onlyAll: false,
      );

      if (paths.isEmpty) {
        setState(() {
          _loading = false;
          _assets = [];
        });
        return;
      }

      final allPath =
          paths.firstWhere((p) => p.isAll, orElse: () => paths.first);
      final assets = await allPath.getAssetListPaged(page: 0, size: 20);

      if (mounted) {
        setState(() {
          _assets = assets;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _assets = [];
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_useNativePhotoGrid) {
      if (_recentFiles.isEmpty) {
        return _DesktopPlaceholder(
          mode: _GalleryMode.photo,
          onPressed: () async {
            final path = await pickImagePathDesktopAware();
            if (path != null) await widget.onPhotoPath(path);
          },
        );
      }
      return ListView.builder(
        controller: widget.scrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        itemCount: _recentFiles.length,
        itemBuilder: (context, index) {
          final path = _recentFiles[index];
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () => widget.onPhotoPath(path),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(
                  File(path),
                  width: 92,
                  height: 92,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          );
        },
      );
    }

    final assets = _assets ?? [];

    if (assets.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'Нет фото в галерее',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    // Horizontal list for compact state
    return ListView.builder(
      controller: widget.scrollController,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      itemCount: assets.length + 1, // +1 for camera
      itemBuilder: (context, index) {
        // First item is camera
        if (index == 0) {
          return _CameraCard(onTap: widget.onOpenCamera);
        }

        final asset = assets[index - 1];
        return _PhotoCard(
          asset: asset,
          index: index - 1,
          onTap: () => _onPhotoTap(asset),
          isSelected: widget.selectedIndices.contains(index - 1),
          onToggleSelection: () {
            final newSelection = Set<int>.from(widget.selectedIndices);
            if (newSelection.contains(index - 1)) {
              newSelection.remove(index - 1);
            } else {
              newSelection.add(index - 1);
            }
            widget.onSelectionChanged(newSelection);
          },
        );
      },
    );
  }

  Future<void> _onPhotoTap(AssetEntity asset) async {
    final file = await asset.file;
    if (file == null || !mounted) return;

    final type = asset.type;
    if (type == AssetType.video) {
      await widget.onVideoPath(file.path);
    } else {
      await widget.onPhotoPath(file.path);
    }

    if (mounted) {
      Navigator.of(context).pop();
    }
  }
}

class _CameraCard extends StatelessWidget {
  final VoidCallback? onTap;

  const _CameraCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 80,
        height: 80,
        margin: const EdgeInsets.only(right: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.camera_alt,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          size: 32,
        ),
      ),
    );
  }
}

class _PhotoCard extends StatefulWidget {
  final AssetEntity asset;
  final int index;
  final VoidCallback onTap;
  final bool isSelected;
  final VoidCallback onToggleSelection;

  const _PhotoCard({
    super.key,
    required this.asset,
    required this.index,
    required this.onTap,
    required this.isSelected,
    required this.onToggleSelection,
  });

  @override
  State<_PhotoCard> createState() => _PhotoCardState();
}

class _PhotoCardState extends State<_PhotoCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _handleTapDown() async {
    await _animationController.forward();
  }

  Future<void> _handleTapUp() async {
    await _animationController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _handleTapDown(),
      onTapUp: (_) {
        _handleTapUp();
        widget.onTap();
      },
      onTapCancel: () => _handleTapUp(),
      onLongPress: widget.onToggleSelection,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: Container(
          width: 80,
          height: 80,
          margin: const EdgeInsets.only(right: 4),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: FutureBuilder<Uint8List?>(
                  future: widget.asset.thumbnailDataWithSize(
                    const ThumbnailSize.square(200),
                  ),
                  builder: (context, snap) {
                    final data = snap.data;
                    if (data == null) {
                      return Container(
                        color: Colors.black.withValues(alpha: 0.28),
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }
                    return Image.memory(
                      data,
                      fit: BoxFit.cover,
                    );
                  },
                ),
              ),
              if (widget.asset.type == AssetType.video)
                const Positioned(
                  bottom: 4,
                  right: 4,
                  child: Icon(
                    Icons.play_circle_fill,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              if (widget.isSelected)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        '${widget.index + 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  final VoidCallback onOpenGallery;
  final VoidCallback onOpenFile;
  final Future<void> Function()? onLocation;
  final Future<void> Function()? onTodo;
  final Future<void> Function()? onPoll;
  final Future<void> Function()? onCalendarEvent;
  final Future<void> Function()? onContact;
  final VoidCallback? onOpenEmojiInsert;

  const _ActionBar({
    super.key,
    required this.onOpenGallery,
    required this.onOpenFile,
    required this.onLocation,
    required this.onTodo,
    required this.onPoll,
    required this.onCalendarEvent,
    required this.onContact,
    required this.onOpenEmojiInsert,
  });

  Future<void> _runAndClose(Future<void> Function() action) async {
    await action();
  }

  List<_ActionItem> _getActionItems(BuildContext context) {
    final items = <_ActionItem>[
      _ActionItem(
        icon: Icons.insert_drive_file,
        label: 'Файл',
        onTap: onOpenFile,
      ),
      if (onLocation != null)
        _ActionItem(
          icon: Icons.location_on,
          label: 'Локация',
          onTap: () => unawaited(_runAndClose(onLocation!)),
        ),
      if (onContact != null)
        _ActionItem(
          icon: Icons.person,
          label: 'Контакт',
          onTap: () => unawaited(_runAndClose(onContact!)),
        ),
      if (onTodo != null)
        _ActionItem(
          icon: Icons.checklist_rtl,
          label: 'Задачи',
          onTap: () => unawaited(_runAndClose(onTodo!)),
        ),
      if (onCalendarEvent != null)
        _ActionItem(
          icon: Icons.event,
          label: 'Событие',
          onTap: () => unawaited(_runAndClose(onCalendarEvent!)),
        ),
      if (onPoll != null)
        _ActionItem(
          icon: Icons.poll,
          label: 'Опрос',
          onTap: () => unawaited(_runAndClose(onPoll!)),
        ),
    ];
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final items = _getActionItems(context);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          childAspectRatio: 1,
          crossAxisSpacing: 8,
          mainAxisSpacing: 16,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return _ActionButton(
            icon: item.icon,
            label: item.label,
            onTap: item.onTap,
          );
        },
      ),
    );
  }
}

class _ActionItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  _ActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.secondaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
              size: 28,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _ExtraActionsMenuTab extends StatelessWidget {
  final BuildContext sheetContext;
  final Future<void> Function()? onLocation;
  final Future<void> Function()? onTodo;
  final Future<void> Function()? onPoll;
  final Future<void> Function()? onCalendarEvent;

  const _ExtraActionsMenuTab({
    required this.sheetContext,
    required this.onLocation,
    required this.onTodo,
    required this.onPoll,
    required this.onCalendarEvent,
  });

  Future<void> _runAndClose(Future<void> Function() action) async {
    Navigator.of(sheetContext).pop();
    await action();
  }

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      if (onLocation != null)
        ListTile(
          leading: const Icon(Icons.location_on_outlined),
          title: const Text('Геометка'),
          onTap: () => unawaited(_runAndClose(onLocation!)),
        ),
      if (onTodo != null)
        ListTile(
          leading: const Icon(Icons.checklist_rtl),
          title: Text(AppL10n.t('cm_todo')),
          onTap: () => unawaited(_runAndClose(onTodo!)),
        ),
      if (onCalendarEvent != null)
        ListTile(
          leading: const Icon(Icons.event_available_outlined),
          title: Text(AppL10n.t('cm_event')),
          onTap: () => unawaited(_runAndClose(onCalendarEvent!)),
        ),
      if (onPoll != null)
        ListTile(
          leading: const Icon(Icons.poll_outlined),
          title: Text(AppL10n.t('cm_poll')),
          onTap: () => unawaited(_runAndClose(onPoll!)),
        ),
    ];
    if (tiles.isEmpty) {
      return const Center(child: Text('Нет доступных действий'));
    }
    return ListView.separated(
      itemCount: tiles.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) => tiles[i],
    );
  }
}

class _EmojiStickersGifTab extends StatefulWidget {
  final BuildContext sheetContext;
  final Future<void> Function(String path) onStickerFromLibrary;
  final Future<void> Function(Uint8List cropped) onStickerCropped;
  final Future<void> Function(String filePath) onGifPath;
  final VoidCallback? onOpenEmojiInsert;

  const _EmojiStickersGifTab({
    required this.sheetContext,
    required this.onStickerFromLibrary,
    required this.onStickerCropped,
    required this.onGifPath,
    required this.onOpenEmojiInsert,
  });

  @override
  State<_EmojiStickersGifTab> createState() => _EmojiStickersGifTabState();
}

class _EmojiStickersGifTabState extends State<_EmojiStickersGifTab>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Стикеры'),
            Tab(text: 'GIF'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _StickerLibraryTab(
                sheetContext: widget.sheetContext,
                onStickerFromLibrary: widget.onStickerFromLibrary,
                onStickerCropped: widget.onStickerCropped,
              ),
              _GalleryTab(
                mode: _GalleryMode.gif,
                onPhotoPath: (_) async {},
                onGifPath: widget.onGifPath,
                onVideoPath: (_) async {},
                sheetContext: widget.sheetContext,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StickerLibraryTab extends StatefulWidget {
  final BuildContext sheetContext;
  final Future<void> Function(String path) onStickerFromLibrary;
  final Future<void> Function(Uint8List cropped) onStickerCropped;

  const _StickerLibraryTab({
    required this.sheetContext,
    required this.onStickerFromLibrary,
    required this.onStickerCropped,
  });

  @override
  State<_StickerLibraryTab> createState() => _StickerLibraryTabState();
}

class _StickerLibraryTabState extends State<_StickerLibraryTab> {
  List<File> _files = [];
  List<StickerPack> _packs = [];
  int _allStickerCount = 0;
  String? _filterPackId;
  bool _loading = true;
  final _picker = ImagePicker();

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
    if (!mounted) return;
    setState(() => _loading = true);
    await StickerCollectionService.instance.init();
    if (!mounted) return;
    final packs = await StickerCollectionService.instance.loadPacks();
    if (!mounted) return;
    final allFlat =
        await StickerCollectionService.instance.stickerFilesNewestFirst();
    if (!mounted) return;
    var filter = _filterPackId;
    if (filter != null && !packs.any((p) => p.id == filter)) {
      filter = null;
    }
    final files =
        await StickerCollectionService.instance.stickerFilesForPack(filter);
    if (mounted) {
      setState(() {
        _packs = packs;
        _filterPackId = filter;
        _allStickerCount = allFlat.length;
        _files = files;
        _loading = false;
      });
    }
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

  Future<void> _createFromPhoto() async {
    final nav = Navigator.of(context);
    final sheetNav = Navigator.of(widget.sheetContext);
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    if (picked.path.toLowerCase().endsWith('.gif')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Для GIF откройте вкладку «GIF»')),
      );
      return;
    }
    final bytes = await File(picked.path).readAsBytes();
    if (!mounted) return;
    final cropped = await nav.push<Uint8List>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => StickerCropScreen(imageBytes: bytes),
      ),
    );
    if (!mounted) return;
    if (cropped != null) {
      sheetNav.pop();
      await widget.onStickerCropped(cropped);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_files.isEmpty && _allStickerCount == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.emoji_emotions_outlined,
                  size: 48, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              Text(
                'Здесь стикеры, которые вы отправляли или добавляли из чатов',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _createFromPhoto,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Создать стикер из фото'),
              ),
            ],
          ),
        ),
      );
    }
    if (_files.isEmpty && _allStickerCount > 0) {
      return Column(
        children: [
          SizedBox(
            height: 70,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _packs.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  // "All stickers" option
                  final isSelected = _filterPackId == null;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: GestureDetector(
                      onTap: () {
                        setState(() => _filterPackId = null);
                        unawaited(_reload());
                      },
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
                final pack = _packs[packIndex];
                final isSelected = _filterPackId == pack.id;
                final firstStickerRel = pack.stickerRelPaths.isNotEmpty
                    ? pack.stickerRelPaths.first
                    : null;

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _filterPackId = pack.id);
                      unawaited(_reload());
                    },
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
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: FutureBuilder<File?>(
                                    future: _getStickerFile(firstStickerRel),
                                    builder: (context, snapshot) {
                                      if (!snapshot.hasData ||
                                          snapshot.data == null) {
                                        return const Icon(Icons.sticky_note_2,
                                            size: 24);
                                      }
                                      return Image.file(
                                        snapshot.data!,
                                        fit: BoxFit.cover,
                                      );
                                    },
                                  ),
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
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'В этом наборе пока нет стикеров. Выберите «Все стикеры» '
                  'или добавьте стикеры в набор в Настройки → Стикеры.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        if (_packs.isNotEmpty)
          SizedBox(
            height: 70,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _packs.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  // "All stickers" option
                  final isSelected = _filterPackId == null;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: GestureDetector(
                      onTap: () {
                        setState(() => _filterPackId = null);
                        unawaited(_reload());
                      },
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
                final pack = _packs[packIndex];
                final isSelected = _filterPackId == pack.id;
                final firstStickerRel = pack.stickerRelPaths.isNotEmpty
                    ? pack.stickerRelPaths.first
                    : null;

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _filterPackId = pack.id);
                      unawaited(_reload());
                    },
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
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: FutureBuilder<File?>(
                                    future: _getStickerFile(firstStickerRel),
                                    builder: (context, snapshot) {
                                      if (!snapshot.hasData ||
                                          snapshot.data == null) {
                                        return const Icon(Icons.sticky_note_2,
                                            size: 24);
                                      }
                                      return Image.file(
                                        snapshot.data!,
                                        fit: BoxFit.cover,
                                      );
                                    },
                                  ),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _createFromPhoto,
              icon: const Icon(Icons.add, size: 20),
              label: const Text('Новый стикер из фото'),
            ),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(6),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
            ),
            itemCount: _files.length,
            itemBuilder: (context, i) {
              final f = _files[i];
              return GestureDetector(
                onTap: () async {
                  final sheetNav = Navigator.of(widget.sheetContext);
                  sheetNav.pop();
                  await widget.onStickerFromLibrary(f.path);
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(f, fit: BoxFit.cover),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FilesGalleryTab extends StatefulWidget {
  final BuildContext sheetContext;
  final Future<void> Function(String path) onFilePath;

  const _FilesGalleryTab({
    required this.sheetContext,
    required this.onFilePath,
  });

  @override
  State<_FilesGalleryTab> createState() => _FilesGalleryTabState();
}

class _FilesGalleryTabState extends State<_FilesGalleryTab> {
  List<String> _recent = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final r = await _loadRecentFilePaths();
    if (mounted) {
      setState(() {
        _recent = r;
        _loading = false;
      });
    }
  }

  Future<void> _browse() async {
    final sheetNav = Navigator.of(widget.sheetContext);
    final r = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: kIsWeb,
    );
    final file = r?.files.single;
    final path = kIsWeb
        ? _webPickedFileUri(file, fallbackMime: 'application/octet-stream')
        : file?.path;
    if (path == null || !mounted) return;
    if (!kIsWeb) await _rememberFilePath(path);
    sheetNav.pop();
    await widget.onFilePath(path);
  }

  String? _webPickedFileUri(PlatformFile? file,
      {required String fallbackMime}) {
    final bytes = file?.bytes;
    if (bytes == null || bytes.isEmpty) return null;
    final mime = _mimeForPickedName(file?.name ?? '', fallbackMime);
    return createWebObjectUrl([bytes], mime) ??
        'data:$mime;base64,${base64Encode(bytes)}';
  }

  String _mimeForPickedName(String name, String fallbackMime) {
    switch (p.extension(name).toLowerCase()) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.webm':
        return 'video/webm';
      case '.mov':
        return 'video/quicktime';
      case '.mp4':
      case '.m4v':
        return 'video/mp4';
      case '.pdf':
        return 'application/pdf';
      default:
        return fallbackMime;
    }
  }

  Future<void> _pickRecent(String path) async {
    final sheetNav = Navigator.of(widget.sheetContext);
    sheetNav.pop();
    await _rememberFilePath(path);
    await widget.onFilePath(path);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _browse,
            icon: const Icon(Icons.folder_open_rounded),
            label: const Text('Выбрать файл'),
          ),
        ),
        if (_recent.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                'Недавно выбранные файлы появятся здесь',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: _recent.length,
              itemBuilder: (context, i) {
                final p = _recent[i];
                final norm = p.replaceAll('\\', '/');
                final name = norm.split('/').last;
                return ListTile(
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title:
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    p,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                  onTap: () => unawaited(_pickRecent(p)),
                );
              },
            ),
          ),
      ],
    );
  }
}

enum _GalleryMode { gif, photo, video }

class _GalleryTab extends StatefulWidget {
  final _GalleryMode mode;
  final Future<void> Function(String filePath) onPhotoPath;
  final Future<void> Function(String filePath) onGifPath;
  final Future<void> Function(String filePath) onVideoPath;
  final BuildContext sheetContext;

  const _GalleryTab({
    required this.mode,
    required this.onPhotoPath,
    required this.onGifPath,
    required this.onVideoPath,
    required this.sheetContext,
  });

  @override
  State<_GalleryTab> createState() => _GalleryTabState();
}

class _GalleryTabState extends State<_GalleryTab> {
  static const int _kPageSize = 200;

  List<AssetEntity>? _assets;
  List<AssetPathEntity>? _albums;
  String? _selectedAlbumId;
  bool _permissionLimited = false;
  String? _error;
  bool _loading = true;

  // Photo mode only: tapping toggles selection (Telegram-style) instead of
  // sending immediately — order in this list is send order, and each cell's
  // badge number is its position here + 1, so removing one renumbers the rest.
  final List<AssetEntity> _selected = [];
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    if (_useNativePhotoGrid) {
      unawaited(_loadNative());
    } else {
      _loading = false;
    }
  }

  RequestType get _requestType =>
      widget.mode == _GalleryMode.video ? RequestType.video : RequestType.image;

  Future<List<AssetEntity>> _filterRawByMode(List<AssetEntity> raw) async {
    if (widget.mode == _GalleryMode.gif) {
      final withMime = await Future.wait(
        raw.map((e) async {
          final m = await e.mimeTypeAsync;
          return _isGifMime(m);
        }),
      );
      return [
        for (var i = 0; i < raw.length; i++)
          if (withMime[i]) raw[i],
      ];
    }
    if (widget.mode == _GalleryMode.photo) {
      final withMime = await Future.wait(
        raw.map((e) async {
          final m = await e.mimeTypeAsync;
          return !_isGifMime(m);
        }),
      );
      return [
        for (var i = 0; i < raw.length; i++)
          if (withMime[i]) raw[i],
      ];
    }
    return raw;
  }

  Future<void> _loadAssetsForAlbum(
    List<AssetPathEntity> albums,
    String albumId,
    bool permissionLimited,
  ) async {
    final album = albums.firstWhere((p) => p.id == albumId);
    final raw = await album.getAssetListPaged(page: 0, size: _kPageSize);
    final filtered = await _filterRawByMode(raw);
    if (!mounted) return;
    setState(() {
      _albums = albums;
      _selectedAlbumId = albumId;
      _permissionLimited = permissionLimited;
      _assets = filtered;
      _loading = false;
    });
  }

  Future<void> _loadNative() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final state = await PhotoManager.requestPermissionExtend();
      if (!state.hasAccess) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'Нет доступа к галерее';
            _assets = [];
            _albums = null;
            _selectedAlbumId = null;
          });
        }
        return;
      }

      final permissionLimited = state.isLimited;
      final paths = await PhotoManager.getAssetPathList(
        type: _requestType,
        hasAll: true,
        onlyAll: false,
      );
      if (paths.isEmpty) {
        if (mounted) {
          setState(() {
            _loading = false;
            _assets = [];
            _albums = [];
            _selectedAlbumId = null;
            _permissionLimited = permissionLimited;
          });
        }
        return;
      }

      final sorted = List<AssetPathEntity>.from(paths)
        ..sort((a, b) {
          if (a.isAll != b.isAll) return a.isAll ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

      final withAll = sorted.where((p) => p.isAll);
      final defaultAlbum = withAll.isNotEmpty ? withAll.first : sorted.first;

      await _loadAssetsForAlbum(sorted, defaultAlbum.id, permissionLimited);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
          _assets = [];
          _albums = null;
          _selectedAlbumId = null;
        });
      }
    }
  }

  Future<void> _onAlbumChanged(String? albumId) async {
    if (albumId == null || _albums == null) return;
    setState(() => _loading = true);
    try {
      await _loadAssetsForAlbum(_albums!, albumId, _permissionLimited);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _openPhotoAccessSettings() async {
    final rt = widget.mode == _GalleryMode.video
        ? RequestType.video
        : RequestType.image;
    if (RuntimePlatform.isIos) {
      await PhotoManager.presentLimited(type: rt);
    } else {
      await PhotoManager.openSetting();
    }
    await _loadNative();
  }

  void _toggleSelected(AssetEntity asset) {
    setState(() {
      if (!_selected.remove(asset)) _selected.add(asset);
    });
  }

  Future<void> _sendSelected() async {
    if (_selected.isEmpty || _sending) return;
    setState(() => _sending = true);
    final ordered = List<AssetEntity>.from(_selected);
    final sheetNav = Navigator.of(widget.sheetContext);
    try {
      for (final asset in ordered) {
        final file = await asset.file;
        if (file == null) continue;
        await widget.onPhotoPath(file.path);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    sheetNav.pop();
  }

  Future<void> _onTapAsset(AssetEntity asset) async {
    // Photos: tap toggles multi-select (Telegram-style numbered badges) —
    // sending happens via the "Отправить N" bar once at least one is picked.
    if (widget.mode == _GalleryMode.photo) {
      _toggleSelected(asset);
      return;
    }

    final sheetNav = Navigator.of(widget.sheetContext);

    final file = await asset.file;
    if (file == null || !mounted) return;
    final path = file.path;

    switch (widget.mode) {
      case _GalleryMode.gif:
        if (!mounted) return;
        sheetNav.pop();
        await widget.onGifPath(path);
        break;
      case _GalleryMode.photo:
        // Unreachable — handled above.
        break;
      case _GalleryMode.video:
        if (!mounted) return;
        sheetNav.pop();
        await widget.onVideoPath(path);
        break;
    }
  }

  Future<void> _desktopPick() async {
    final sheetNav = Navigator.of(widget.sheetContext);

    switch (widget.mode) {
      case _GalleryMode.gif:
        final r = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['gif'],
          withData: kIsWeb,
        );
        final file = r?.files.single;
        final path = kIsWeb
            ? _webPickedFileUri(file, fallbackMime: 'image/gif')
            : file?.path;
        if (path == null || !mounted) return;
        sheetNav.pop();
        await widget.onGifPath(path);
        break;
      case _GalleryMode.photo:
        if (kIsWeb) {
          final r = await FilePicker.platform.pickFiles(
            type: FileType.image,
            withData: true,
          );
          final path =
              _webPickedFileUri(r?.files.single, fallbackMime: 'image/jpeg');
          if (path == null || !mounted) return;
          sheetNav.pop();
          await widget.onPhotoPath(path);
          break;
        }
        final raw = await pickImagePathDesktopAware();
        if (raw == null || !mounted) return;
        sheetNav.pop();
        await widget.onPhotoPath(raw);
        break;
      case _GalleryMode.video:
        if (kIsWeb) {
          final r = await FilePicker.platform.pickFiles(
            type: FileType.video,
            withData: true,
          );
          final path =
              _webPickedFileUri(r?.files.single, fallbackMime: 'video/mp4');
          if (path == null || !mounted) return;
          sheetNav.pop();
          await widget.onVideoPath(path);
          break;
        }
        final picked =
            await ImagePicker().pickVideo(source: ImageSource.gallery);
        if (picked == null || !mounted) return;
        sheetNav.pop();
        await widget.onVideoPath(picked.path);
        break;
    }
  }

  String? _webPickedFileUri(PlatformFile? file,
      {required String fallbackMime}) {
    final bytes = file?.bytes;
    if (bytes == null || bytes.isEmpty) return null;
    final mime = _mimeForPickedName(file?.name ?? '', fallbackMime);
    return createWebObjectUrl([bytes], mime) ??
        'data:$mime;base64,${base64Encode(bytes)}';
  }

  String _mimeForPickedName(String name, String fallbackMime) {
    switch (p.extension(name).toLowerCase()) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.webm':
        return 'video/webm';
      case '.mov':
        return 'video/quicktime';
      case '.mp4':
      case '.m4v':
        return 'video/mp4';
      default:
        return fallbackMime;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_useNativePhotoGrid) {
      return _DesktopPlaceholder(
        mode: widget.mode,
        onPressed: _desktopPick,
      );
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loadNative,
                child: Text(AppL10n.t('common_retry')),
              ),
              const SizedBox(height: 8),
              const TextButton(
                onPressed: PhotoManager.openSetting,
                child: Text('Настройки доступа'),
              ),
            ],
          ),
        ),
      );
    }

    final assets = _assets ?? [];
    final albums = _albums;

    Widget gridOrEmpty() {
      if (assets.isEmpty) {
        return Center(
          child: Text(
            widget.mode == _GalleryMode.gif
                ? 'Нет GIF в этом альбоме'
                : 'Нет элементов в этом альбоме',
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
        );
      }
      return GridView.builder(
        padding: const EdgeInsets.all(6),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
        ),
        itemCount: assets.length,
        itemBuilder: (context, index) {
          final asset = assets[index];
          final selIndex =
              widget.mode == _GalleryMode.photo ? _selected.indexOf(asset) : -1;
          final selected = selIndex >= 0;
          return GestureDetector(
            onTap: () => _onTapAsset(asset),
            child: FutureBuilder<Uint8List?>(
              future: asset.thumbnailDataWithSize(
                const ThumbnailSize.square(220),
              ),
              builder: (context, snap) {
                final d = snap.data;
                if (d == null) {
                  return Container(
                    color: Colors.black.withValues(alpha: 0.28),
                    alignment: Alignment.center,
                    child: const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(d, fit: BoxFit.cover),
                    if (selected)
                      Container(color: Colors.black.withValues(alpha: 0.25)),
                    if (asset.type == AssetType.video)
                      const Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.play_circle_fill,
                              color: Colors.white, size: 22),
                        ),
                      ),
                    if (widget.mode == _GalleryMode.photo)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selected
                                ? Theme.of(context).colorScheme.primary
                                : Colors.black.withValues(alpha: 0.35),
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          child: selected
                              ? Text(
                                  '${selIndex + 1}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                )
                              : null,
                        ),
                      ),
                  ],
                );
              },
            ),
          );
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_permissionLimited)
          Material(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Ограниченный доступ к фото: видны не все снимки. '
                      'Откройте полный доступ или выберите альбом (например «Камера»).',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.25,
                        color:
                            Theme.of(context).colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => unawaited(_openPhotoAccessSettings()),
                    child: const Text('Доступ'),
                  ),
                ],
              ),
            ),
          ),
        if (albums != null && albums.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: DropdownButtonFormField<String>(
              initialValue: _selectedAlbumId,
              decoration: const InputDecoration(
                labelText: 'Альбом',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              isExpanded: true,
              items: [
                for (final p in albums)
                  DropdownMenuItem<String>(
                    value: p.id,
                    child: Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (id) => unawaited(_onAlbumChanged(id)),
            ),
          ),
        Expanded(child: gridOrEmpty()),
        if (widget.mode == _GalleryMode.photo && _selected.isNotEmpty)
          _SelectedPhotosBar(
            selected: _selected,
            sending: _sending,
            onRemove: _toggleSelected,
            onSend: _sendSelected,
          ),
      ],
    );
  }
}

/// Shown once at least one photo is picked: a filmstrip of what's about to be
/// sent — each thumbnail keeps its own aspect ratio (not force-cropped square)
/// so portrait/landscape shots are distinguishable at a glance — plus the
/// "Отправить N" action, exactly Telegram's multi-select flow.
class _SelectedPhotosBar extends StatelessWidget {
  final List<AssetEntity> selected;
  final bool sending;
  final void Function(AssetEntity) onRemove;
  final VoidCallback onSend;

  const _SelectedPhotosBar({
    required this.selected,
    required this.sending,
    required this.onRemove,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 72,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              itemCount: selected.length,
              itemBuilder: (context, i) {
                final asset = selected[i];
                final ratio = (asset.width > 0 && asset.height > 0)
                    ? asset.width / asset.height
                    : 1.0;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GestureDetector(
                    onTap: () => onRemove(asset),
                    child: AspectRatio(
                      aspectRatio: ratio.clamp(0.5, 2.0),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            FutureBuilder<Uint8List?>(
                              future: asset.thumbnailDataWithSize(
                                const ThumbnailSize(160, 160),
                              ),
                              builder: (context, snap) {
                                final d = snap.data;
                                if (d == null) {
                                  return Container(
                                      color:
                                          Colors.black.withValues(alpha: 0.15));
                                }
                                return Image.memory(d, fit: BoxFit.contain);
                              },
                            ),
                            Positioned(
                              top: 2,
                              right: 2,
                              child: Container(
                                width: 18,
                                height: 18,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.black54,
                                ),
                                child: const Icon(Icons.close,
                                    size: 12, color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: sending ? null : onSend,
                icon: sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send_rounded, size: 18),
                label: Text('Отправить ${selected.length}'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopPlaceholder extends StatelessWidget {
  final _GalleryMode mode;
  final VoidCallback onPressed;

  const _DesktopPlaceholder({
    required this.mode,
    required this.onPressed,
  });

  String get _label {
    switch (mode) {
      case _GalleryMode.gif:
        return 'Выбрать GIF';
      case _GalleryMode.photo:
        return 'Выбрать фото';
      case _GalleryMode.video:
        return 'Выбрать видео';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: FilledButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.folder_open_rounded),
          label: Text(_label),
        ),
      ),
    );
  }
}
