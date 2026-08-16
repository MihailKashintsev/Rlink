import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/sticker_pack.dart';
import '../utils/web_file_store.dart';

/// Локальная коллекция стикеров (свои и добавленные из чатов).
/// • Native: файлы `images/stk_*` + индексы `sticker_collection.json` /
///   `sticker_packs.json` в documents.
/// • Web: индексы в OPFS; сами картинки хранятся как inline `data:` URL прямо
///   в [StickerPack.stickerRelPaths] / the flat list (same trick as
///   EmojiPackService — makes stickers renderable via Image.memory/network
///   without a real filesystem).
class StickerCollectionService {
  StickerCollectionService._();
  static final StickerCollectionService instance = StickerCollectionService._();

  final ValueNotifier<int> version = ValueNotifier(0);
  static const _jsonName = 'sticker_collection.json';
  static const _packsJsonName = 'sticker_packs.json';
  static const _webListPath = 'opfs://rlink/$_jsonName';
  static const _webPacksPath = 'opfs://rlink/$_packsJsonName';
  static const _defaultPackAssetPrefix = 'assets/sticker_packs/default/';
  static const _defaultPackAssetNames = <String>[
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
  final _uuid = const Uuid();

  static bool isDataOrRemote(String ref) =>
      ref.startsWith('data:') ||
      ref.startsWith('http://') ||
      ref.startsWith('https://') ||
      ref.startsWith('opfs://');

  /// Инициализация коллекции и подстановка встроенного набора при пустом списке.
  Future<void> init() async {
    await ensureInitialized();
    await _seedDefaultPackIfEmpty();
  }

  /// Принудительное обновление дефолтного набора новыми стикерами
  Future<void> forceReseedDefaultPack() async {
    final packs = await _readPacks();
    for (final pack in packs) {
      if (pack.title == 'Rlink' && pack.sourcePeerId == null) {
        await deletePack(pack.id);
      }
    }
    final rels = await _seedDefaultPackAssets(skipExisting: true);
    if (rels.isEmpty) return;
    await createPack(title: 'Rlink', relPaths: rels);
    debugPrint('[Stickers] reseeded default pack (${rels.length} files)');
  }

  Future<void> _seedDefaultPackIfEmpty() async {
    final packs = await _readPacks();
    if (packs.isNotEmpty) return;
    final rels = await _seedDefaultPackAssets(skipExisting: false);
    if (rels.isEmpty) return;
    await createPack(title: 'Rlink', relPaths: rels);
    debugPrint('[Stickers] seeded default pack (${rels.length} files)');
  }

  Future<List<String>> _seedDefaultPackAssets({required bool skipExisting}) async {
    final rels = <String>[];
    Directory? imgDir;
    if (!kIsWeb) {
      final docs = await getApplicationDocumentsDirectory();
      imgDir = Directory(p.join(docs.path, 'images'));
      if (!imgDir.existsSync()) imgDir.createSync(recursive: true);
    }
    for (final name in _defaultPackAssetNames) {
      try {
        final data = await rootBundle.load('$_defaultPackAssetPrefix$name');
        final destName =
            'stk_default_${name.replaceAll('.png', '').replaceAll('.webp', '')}${p.extension(name)}';
        if (kIsWeb) {
          rels.add(_dataUrlFor(data.buffer.asUint8List(), _mimeForExt(p.extension(name))));
        } else {
          final dest = File(p.join(imgDir!.path, destName));
          if (!skipExisting || !await dest.exists()) {
            await dest.writeAsBytes(data.buffer.asUint8List());
          }
          rels.add(p.join('images', destName));
        }
      } catch (e, st) {
        debugPrint('[Stickers] default asset $name: $e\n$st');
      }
    }
    return rels;
  }

  static String _mimeForExt(String ext) {
    switch (ext.toLowerCase()) {
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.rls':
        return 'application/octet-stream';
      default:
        return 'image/png';
    }
  }

  static String _dataUrlFor(Uint8List bytes, String mime) =>
      'data:$mime;base64,${base64Encode(bytes)}';

  Future<File> _jsonFile() async {
    final d = await getApplicationDocumentsDirectory();
    return File(p.join(d.path, _jsonName));
  }

  Future<File> _packsFile() async {
    final d = await getApplicationDocumentsDirectory();
    return File(p.join(d.path, _packsJsonName));
  }

  Future<void> ensureInitialized() async {
    if (kIsWeb) return; // OPFS reads default to empty; nothing to pre-create.
    final f = await _jsonFile();
    if (!await f.exists()) {
      await syncFromDisk();
    }
    final pf = await _packsFile();
    if (!await pf.exists()) {
      await _writePacks(const []);
    }
  }

  Future<List<String>> _readList() async {
    if (kIsWeb) {
      final bytes = await readWebStoredFile(_webListPath);
      if (bytes == null || bytes.isEmpty) return [];
      try {
        return (jsonDecode(utf8.decode(bytes)) as List).cast<String>();
      } catch (_) {
        return [];
      }
    }
    final f = await _jsonFile();
    if (!await f.exists()) return [];
    try {
      return (jsonDecode(await f.readAsString()) as List).cast<String>();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeList(List<String> relPaths) async {
    if (kIsWeb) {
      await writeWebStoredFile(
        fileName: _jsonName,
        bytes: Uint8List.fromList(utf8.encode(jsonEncode(relPaths))),
        mimeType: 'application/json',
      );
      version.value++;
      return;
    }
    final f = await _jsonFile();
    await f.writeAsString(jsonEncode(relPaths));
    version.value++;
  }

  Future<List<StickerPack>> _readPacks() async {
    await ensureInitialized();
    if (kIsWeb) {
      final bytes = await readWebStoredFile(_webPacksPath);
      if (bytes == null || bytes.isEmpty) return [];
      try {
        return StickerPack.decodeList(utf8.decode(bytes));
      } catch (_) {
        return [];
      }
    }
    final f = await _packsFile();
    if (!await f.exists()) return [];
    try {
      final raw = await f.readAsString();
      final list = StickerPack.decodeList(raw);
      final pruned = await _prunePackPaths(list);
      if (!_packListsEqual(list, pruned)) {
        await _writePacksRaw(pruned);
      }
      return pruned;
    } catch (_) {
      return [];
    }
  }

  bool _packListsEqual(List<StickerPack> a, List<StickerPack> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
      if (a[i].stickerRelPaths.length != b[i].stickerRelPaths.length) {
        return false;
      }
    }
    return true;
  }

  Future<void> _writePacksRaw(List<StickerPack> packs) async {
    if (kIsWeb) {
      await writeWebStoredFile(
        fileName: _packsJsonName,
        bytes: Uint8List.fromList(utf8.encode(StickerPack.encodeList(packs))),
        mimeType: 'application/json',
      );
      version.value++;
      return;
    }
    final f = await _packsFile();
    await f.writeAsString(StickerPack.encodeList(packs));
    version.value++;
  }

  Future<void> _writePacks(List<StickerPack> packs) => _writePacksRaw(packs);

  Future<List<StickerPack>> _prunePackPaths(List<StickerPack> packs) async {
    // Web entries are inline data: URLs — nothing on "disk" to go stale.
    if (kIsWeb) return packs;
    final docs = await getApplicationDocumentsDirectory();
    var changed = false;
    final out = <StickerPack>[];
    for (final pack in packs) {
      final keep = <String>[];
      for (final rel in pack.stickerRelPaths) {
        if (isDataOrRemote(rel) || File(p.join(docs.path, rel)).existsSync()) {
          keep.add(rel);
        } else {
          changed = true;
        }
      }
      out.add(StickerPack(
        id: pack.id,
        title: pack.title,
        createdAtMs: pack.createdAtMs,
        stickerRelPaths: keep,
        sourcePeerId: pack.sourcePeerId,
        sourcePeerLabel: pack.sourcePeerLabel,
      ));
    }
    if (changed) {
      debugPrint('[Stickers] pruned missing files from packs');
    }
    return out;
  }

  /// Пути относительно каталога документов приложения (native) или data:
  /// URLs (web) — valid, renderable refs for the flat collection.
  Future<List<String>> relativePathsValid() async {
    final raw = await _readList();
    if (kIsWeb) return raw;
    final docs = await getApplicationDocumentsDirectory();
    final out = <String>[];
    for (final rel in raw) {
      if (isDataOrRemote(rel) || File(p.join(docs.path, rel)).existsSync()) {
        out.add(rel);
      }
    }
    if (out.length != raw.length) {
      await _writeList(out);
    }
    return out;
  }

  /// Renderable refs (native abs paths or web data: URLs), newest first.
  Future<List<String>> stickerFilesNewestFirst() async {
    final rels = await relativePathsValid();
    if (kIsWeb) {
      // Web list is already maintained newest-first on insert.
      return rels;
    }
    final docs = await getApplicationDocumentsDirectory();
    final files = <File>[];
    for (final r in rels) {
      final f = File(p.join(docs.path, r));
      if (f.existsSync()) files.add(f);
    }
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files.map((f) => f.path).toList();
  }

  /// Renderable refs for a pack in order; [packId] == null — the whole
  /// collection (like [stickerFilesNewestFirst]).
  Future<List<String>> stickerFilesForPack(String? packId) async {
    if (packId == null || packId.isEmpty) {
      return stickerFilesNewestFirst();
    }
    final packs = await _readPacks();
    StickerPack? pack;
    for (final e in packs) {
      if (e.id == packId) {
        pack = e;
        break;
      }
    }
    if (pack == null) return stickerFilesNewestFirst();
    if (kIsWeb) return pack.stickerRelPaths;
    final docs = await getApplicationDocumentsDirectory();
    final out = <String>[];
    for (final rel in pack.stickerRelPaths) {
      if (File(p.join(docs.path, rel)).existsSync()) out.add(rel);
    }
    return out;
  }

  /// Resolves a relative sticker path (as stored on [StickerPack]) to a
  /// renderable ref — the data: URL unchanged on web, the absolute file path
  /// on native — or null if missing.
  Future<String?> absoluteFileForRel(String relPath) async {
    if (kIsWeb || isDataOrRemote(relPath)) return relPath;
    final docs = await getApplicationDocumentsDirectory();
    final f = File(p.join(docs.path, relPath));
    return f.existsSync() ? f.path : null;
  }

  Future<List<StickerPack>> loadPacks() => _readPacks();

  Future<StickerPack?> packById(String id) async {
    final packs = await _readPacks();
    for (final e in packs) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Подтянуть в JSON все `images/stk_*` с диска. No-op on web (nothing to
  /// scan — entries only ever arrive via registerStickerBytes/register*).
  Future<void> syncFromDisk() async {
    if (kIsWeb) return;
    final docs = await getApplicationDocumentsDirectory();
    final imgDir = Directory(p.join(docs.path, 'images'));
    final fromDisk = <String>{};
    if (imgDir.existsSync()) {
      for (final e in imgDir.listSync()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (name.startsWith('stk_')) {
          fromDisk.add(p.join('images', name));
        }
      }
    }
    final merged = {...await _readList(), ...fromDisk}.toList()..sort();
    await _writeList(merged);
  }

  Future<String> _ensureRelForAbsolute(String absPath) async {
    if (kIsWeb) {
      throw UnsupportedError(
          'registerAbsoluteStickerPath needs a real file path — use registerStickerBytes on web');
    }
    final docs = await getApplicationDocumentsDirectory();
    final norm = p.normalize(absPath);
    if (!File(norm).existsSync()) {
      throw StateError('file missing');
    }
    late final String rel;
    if (norm.startsWith(docs.path)) {
      rel = p.relative(norm, from: docs.path);
    } else {
      final destDir = Directory(p.join(docs.path, 'images'));
      if (!destDir.existsSync()) destDir.createSync(recursive: true);
      final ext = p.extension(norm);
      final safeExt =
          (ext.isNotEmpty && ext.length <= 6) ? ext.toLowerCase() : '.jpg';
      final name = 'stk_${_uuid.v4()}$safeExt';
      final dest = File(p.join(destDir.path, name));
      await File(norm).copy(dest.path);
      rel = p.join('images', name);
    }
    final list = await _readList();
    if (!list.contains(rel)) {
      list.insert(0, rel);
      await _writeList(list);
    } else {
      version.value++;
    }
    return rel;
  }

  /// Cross-platform sticker registration from raw bytes — the entry point for
  /// anything that doesn't already have a native file (image_picker bytes on
  /// web, a freshly-exported .rls sticker, downloaded bytes). Native writes a
  /// real file and delegates to the same path as registerAbsoluteStickerPath;
  /// web stores an inline data: URL. Returns the renderable ref.
  Future<String> registerStickerBytes({
    required Uint8List bytes,
    String ext = '.png',
  }) async {
    if (kIsWeb) {
      final ref = _dataUrlFor(bytes, _mimeForExt(ext));
      final list = await _readList();
      list.insert(0, ref);
      await _writeList(list);
      return ref;
    }
    final docs = await getApplicationDocumentsDirectory();
    final destDir = Directory(p.join(docs.path, 'images'));
    if (!destDir.existsSync()) destDir.createSync(recursive: true);
    final safeExt = ext.isNotEmpty && ext.length <= 6 ? ext.toLowerCase() : '.png';
    final name = 'stk_${_uuid.v4()}$safeExt';
    final dest = File(p.join(destDir.path, name));
    await dest.writeAsBytes(bytes);
    return _ensureRelForAbsolute(dest.path);
  }

  /// Зарегистрировать файл стикера (уже в sandbox или скопировать в `images/stk_*`).
  /// Native only — pass bytes via [registerStickerBytes] on web.
  Future<void> registerAbsoluteStickerPath(String absPath) async {
    if (kIsWeb) return;
    await _ensureRelForAbsolute(absPath);
  }

  Future<void> importChatImageToCollection(String imageAbsPath) async {
    if (kIsWeb) return;
    if (!File(imageAbsPath).existsSync()) return;
    await registerAbsoluteStickerPath(imageAbsPath);
  }

  /// Создать набор. [relPaths] — относительные пути (native) или data: URLs
  /// (web); entries that no longer resolve are filtered out.
  Future<String> createPack({
    required String title,
    List<String> relPaths = const [],
    String? sourcePeerId,
    String? sourcePeerLabel,
  }) async {
    await ensureInitialized();
    final packs = await _readPacks();
    final id = _uuid.v4();
    final valid = await _validRels(relPaths);
    final t = title.trim().isEmpty ? 'Набор' : title.trim();
    packs.insert(
      0,
      StickerPack(
        id: id,
        title: t,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        stickerRelPaths: valid,
        sourcePeerId: sourcePeerId,
        sourcePeerLabel: sourcePeerLabel,
      ),
    );
    await _writePacks(packs);
    return id;
  }

  Future<List<String>> _validRels(List<String> relPaths) async {
    final seen = <String>{};
    final valid = <String>[];
    final docs = kIsWeb ? null : await getApplicationDocumentsDirectory();
    for (final r in relPaths) {
      if (!seen.add(r)) continue;
      if (kIsWeb || isDataOrRemote(r)) {
        valid.add(r);
      } else if (File(p.join(docs!.path, r)).existsSync()) {
        valid.add(r);
      }
    }
    return valid;
  }

  Future<void> deletePack(String packId) async {
    final packs = await _readPacks();
    packs.removeWhere((e) => e.id == packId);
    await _writePacks(packs);
  }

  Future<void> renamePack(String packId, String newTitle) async {
    final packs = await _readPacks();
    final i = packs.indexWhere((e) => e.id == packId);
    if (i < 0) return;
    final p0 = packs[i];
    final t = newTitle.trim().isEmpty ? p0.title : newTitle.trim();
    packs[i] = StickerPack(
      id: p0.id,
      title: t,
      createdAtMs: p0.createdAtMs,
      stickerRelPaths: p0.stickerRelPaths,
      sourcePeerId: p0.sourcePeerId,
      sourcePeerLabel: p0.sourcePeerLabel,
    );
    await _writePacks(packs);
  }

  Future<void> setPackStickerRels(String packId, List<String> relPaths) async {
    final packs = await _readPacks();
    final i = packs.indexWhere((e) => e.id == packId);
    if (i < 0) return;
    final p0 = packs[i];
    final valid = await _validRels(relPaths);
    packs[i] = StickerPack(
      id: p0.id,
      title: p0.title,
      createdAtMs: p0.createdAtMs,
      stickerRelPaths: valid,
      sourcePeerId: p0.sourcePeerId,
      sourcePeerLabel: p0.sourcePeerLabel,
    );
    await _writePacks(packs);
  }

  /// Импорт копий в галерею + новый набор (стикеры от контакта). Native only
  /// — pass raw bytes via [importPackFromBytesList] on web.
  Future<String> importPackFromAbsolutePaths({
    required String title,
    required List<String> absPaths,
    String? sourcePeerId,
    String? sourcePeerLabel,
  }) async {
    final rels = <String>[];
    for (final a in absPaths) {
      try {
        rels.add(await _ensureRelForAbsolute(a));
      } catch (_) {}
    }
    return createPack(
      title: title,
      relPaths: rels,
      sourcePeerId: sourcePeerId,
      sourcePeerLabel: sourcePeerLabel,
    );
  }

  /// Cross-platform pack import from raw bytes (a received pack's decoded
  /// sticker files) — works on both native and web.
  Future<String> importPackFromBytesList({
    required String title,
    required List<Uint8List> bytesList,
    List<String> exts = const [],
    String? sourcePeerId,
    String? sourcePeerLabel,
  }) async {
    final rels = <String>[];
    for (var i = 0; i < bytesList.length; i++) {
      final ext = i < exts.length && exts[i].isNotEmpty ? exts[i] : '.png';
      try {
        rels.add(await registerStickerBytes(bytes: bytesList[i], ext: ext));
      } catch (_) {}
    }
    return createPack(
      title: title,
      relPaths: rels,
      sourcePeerId: sourcePeerId,
      sourcePeerLabel: sourcePeerLabel,
    );
  }

  /// Относительный путь для файла внутри sandbox (без копирования). Native only.
  Future<String?> relativePathIfInAppDocs(String absPath) async {
    if (kIsWeb) return null;
    final docs = await getApplicationDocumentsDirectory();
    final norm = p.normalize(absPath);
    if (!norm.startsWith(docs.path)) return null;
    return p.relative(norm, from: docs.path);
  }
}
