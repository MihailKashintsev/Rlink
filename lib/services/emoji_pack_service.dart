import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show ImageProvider, FileImage, MemoryImage;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/emoji_pack.dart';
import '../utils/web_file_store.dart';

/// Локальные наборы кастомных эмодзи.
/// • Native: каталог [emoji_packs/] + индекс [emoji_packs.json] в documents.
/// • Web: индекс в OPFS (`emoji_packs.json`); сами картинки хранятся как
///   inline data-URL прямо в [CustomEmoji.relPath] (рендер через MemoryImage,
///   синхронно). Это делает кастом-эмодзи рабочими и синхронизируемыми на вебе.
class EmojiPackService {
  EmojiPackService._();
  static final EmojiPackService instance = EmojiPackService._();

  final ValueNotifier<int> version = ValueNotifier(0);
  static const _jsonName = 'emoji_packs.json';
  static const _packDirName = 'emoji_packs';
  // OPFS path for the web index (writeWebStoredFile keeps the name stable).
  static const _webIndexPath = 'opfs://rlink/$_jsonName';

  final _uuid = const Uuid();
  String? _docsRoot;

  /// In-memory source of truth (mirrors the file/OPFS index). Lets the
  /// shortcode maps rebuild synchronously on every platform.
  List<EmojiPack> _cachedPacks = [];
  bool _initialised = false;

  /// shortcode (lower) → native absolute path OR web data-URL (for sync render).
  final Map<String, String> _shortcodeToRef = {};

  /// shortcode (lower) → исходный регистр shortcode + relPath
  final Map<String, CustomEmoji> _shortcodeToEmoji = {};

  // ── Storage primitives (branch web/native) ──────────────────────

  Future<File> _packsFile() async {
    final d = await getApplicationDocumentsDirectory();
    return File(p.join(d.path, _jsonName));
  }

  Future<Directory> _packsRootDir() async {
    final d = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(d.path, _packDirName));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<String?> _readIndexRaw() async {
    if (kIsWeb) {
      final bytes = await readWebStoredFile(_webIndexPath);
      if (bytes == null || bytes.isEmpty) return null;
      try {
        return utf8.decode(bytes);
      } catch (_) {
        return null;
      }
    }
    final f = await _packsFile();
    if (!await f.exists()) return null;
    return f.readAsString();
  }

  Future<void> _writeIndexRaw(String json) async {
    if (kIsWeb) {
      await writeWebStoredFile(
        fileName: _jsonName,
        bytes: Uint8List.fromList(utf8.encode(json)),
        mimeType: 'application/json',
      );
      return;
    }
    final f = await _packsFile();
    await f.writeAsString(json);
  }

  // ── Init / index ────────────────────────────────────────────────

  Future<void> ensureInitialized() async {
    if (!kIsWeb) {
      final d = await getApplicationDocumentsDirectory();
      _docsRoot = d.path;
      final f = await _packsFile();
      if (!await f.exists()) {
        await f.writeAsString(EmojiPack.encodeList(const []));
      }
      await _packsRootDir();
    }
    if (!_initialised) {
      final raw = await _readIndexRaw();
      _cachedPacks = raw == null ? [] : EmojiPack.decodeList(raw);
      _initialised = true;
    }
    refreshIndexSync();
  }

  void refreshIndexSync() {
    _shortcodeToRef.clear();
    _shortcodeToEmoji.clear();
    for (final pack in _cachedPacks) {
      for (final e in pack.emojis) {
        final k = e.shortcode.toLowerCase();
        if (_shortcodeToRef.containsKey(k)) continue;
        final String ref;
        if (kIsWeb) {
          // relPath holds the data-URL on web.
          if (!e.relPath.startsWith('data:')) continue;
          ref = e.relPath;
        } else {
          final root = _docsRoot;
          if (root == null) continue;
          final abs = p.join(root, e.relPath);
          if (!File(abs).existsSync()) continue;
          ref = abs;
        }
        _shortcodeToRef[k] = ref;
        _shortcodeToEmoji[k] =
            CustomEmoji(shortcode: e.shortcode, relPath: e.relPath);
      }
    }
  }

  /// Clears every custom emoji pack (used by a full account reset,
  /// including account transfer's old-device wipe) — same orphaned-native-
  /// file trade-off as `StickerCollectionService.resetAll()`.
  Future<void> resetAll() async {
    await ensureInitialized();
    _cachedPacks = [];
    await _writeIndexRaw(EmojiPack.encodeList(const []));
    refreshIndexSync();
    version.value++;
  }

  Future<List<EmojiPack>> _readPacksRaw() async {
    await ensureInitialized();
    return await _pruneMissingFiles(List<EmojiPack>.from(_cachedPacks));
  }

  Future<List<EmojiPack>> _pruneMissingFiles(List<EmojiPack> packs) async {
    if (kIsWeb) return packs; // data-URLs are always present
    final docs = await getApplicationDocumentsDirectory();
    var changed = false;
    final out = <EmojiPack>[];
    for (final pack in packs) {
      final keep = <CustomEmoji>[];
      for (final e in pack.emojis) {
        if (File(p.join(docs.path, e.relPath)).existsSync()) {
          keep.add(e);
        } else {
          changed = true;
        }
      }
      out.add(EmojiPack(
        id: pack.id,
        name: pack.name,
        emojis: keep,
        sourcePeerId: pack.sourcePeerId,
      ));
    }
    if (changed) await _writePacks(out);
    return out;
  }

  Future<void> _writePacks(List<EmojiPack> packs) async {
    _cachedPacks = List<EmojiPack>.from(packs);
    await _writeIndexRaw(EmojiPack.encodeList(packs));
    refreshIndexSync();
    version.value++;
  }

  Future<void> warmIndex() async {
    await ensureInitialized();
    refreshIndexSync();
  }

  Future<List<EmojiPack>> loadPacks() => _readPacksRaw();

  Future<EmojiPack?> packById(String id) async {
    final packs = await _readPacksRaw();
    for (final e in packs) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Which local pack a shortcode belongs to, if any — used when building an
  /// auto-collect payload so the recipient can sort it into a sensibly named
  /// pack instead of one generic dump bucket.
  String? packNameForShortcode(String shortcode) {
    final k = shortcode.trim().toLowerCase();
    if (k.isEmpty) return null;
    for (final pack in _cachedPacks) {
      for (final e in pack.emojis) {
        if (e.shortcode.toLowerCase() == k) return pack.name;
      }
    }
    return null;
  }

  CustomEmoji? lookupByShortcode(String shortcode) {
    final k = shortcode.trim().toLowerCase();
    if (k.isEmpty) return null;
    final em = _shortcodeToEmoji[k];
    if (em == null) return null;
    if (!kIsWeb) {
      final abs = _shortcodeToRef[k];
      if (abs == null || !File(abs).existsSync()) return null;
    }
    return em;
  }

  Future<List<EmojiPack>> packsContainingShortcode(String shortcode) async {
    final sc = shortcode.trim().toLowerCase();
    if (sc.isEmpty) return const [];
    final packs = await _readPacksRaw();
    final out = <EmojiPack>[];
    for (final pack in packs) {
      if (pack.emojis.any((e) => e.shortcode.toLowerCase() == sc)) {
        out.add(pack);
      }
    }
    return out;
  }

  /// Native absolute path for a shortcode (null on web — use [emojiImageProvider]).
  String? absolutePathForShortcode(String shortcode) {
    if (kIsWeb) return null;
    final k = shortcode.trim().toLowerCase();
    final abs = _shortcodeToRef[k];
    if (abs == null || !File(abs).existsSync()) return null;
    return abs;
  }

  /// A ready ImageProvider for a custom emoji shortcode — works on every
  /// platform (FileImage on native, MemoryImage from the data-URL on web).
  ImageProvider? emojiImageProvider(String shortcode) {
    final k = shortcode.trim().toLowerCase();
    final ref = _shortcodeToRef[k];
    if (ref == null) return null;
    if (ref.startsWith('data:')) {
      final comma = ref.indexOf(',');
      if (comma < 0) return null;
      try {
        return MemoryImage(base64Decode(ref.substring(comma + 1)));
      } catch (_) {
        return null;
      }
    }
    if (!File(ref).existsSync()) return null;
    return FileImage(File(ref));
  }

  Future<String?> absolutePathForEmoji(CustomEmoji e) async {
    if (kIsWeb) return null;
    final docs = await getApplicationDocumentsDirectory();
    final abs = p.join(docs.path, e.relPath);
    if (File(abs).existsSync()) return abs;
    return null;
  }

  Future<Uint8List?> readEmojiBytesByShortcode(String shortcode) async {
    await ensureInitialized();
    final k = shortcode.trim().toLowerCase();
    final ref = _shortcodeToRef[k];
    if (ref == null) return null;
    if (ref.startsWith('data:')) {
      final comma = ref.indexOf(',');
      if (comma < 0) return null;
      try {
        return base64Decode(ref.substring(comma + 1));
      } catch (_) {
        return null;
      }
    }
    final f = File(ref);
    if (!f.existsSync()) return null;
    return f.readAsBytes();
  }

  // ── Mutations ───────────────────────────────────────────────────

  Future<String> createPack({
    required String name,
    String? sourcePeerId,
  }) async {
    await ensureInitialized();
    final packs = await _readPacksRaw();
    final id = _uuid.v4();
    if (!kIsWeb) {
      final root = await _packsRootDir();
      Directory(p.join(root.path, id)).createSync(recursive: true);
    }
    final n = name.trim().isEmpty ? 'Набор' : name.trim();
    packs.insert(
      0,
      EmojiPack(id: id, name: n, emojis: const [], sourcePeerId: sourcePeerId),
    );
    await _writePacks(packs);
    return id;
  }

  Future<void> renamePack(String packId, String newName) async {
    final packs = await _readPacksRaw();
    final i = packs.indexWhere((e) => e.id == packId);
    if (i < 0) return;
    final p0 = packs[i];
    final n = newName.trim().isEmpty ? p0.name : newName.trim();
    packs[i] = EmojiPack(
      id: p0.id,
      name: n,
      emojis: p0.emojis,
      sourcePeerId: p0.sourcePeerId,
    );
    await _writePacks(packs);
  }

  /// Adds an emoji from raw image bytes (works on web + native).
  Future<void> addEmojiBytes({
    required String packId,
    required String shortcode,
    required Uint8List bytes,
    String ext = '.png',
  }) async {
    final sc = _normalizeShortcode(shortcode);
    if (sc == null) throw ArgumentError('invalid shortcode');
    if (bytes.isEmpty) throw StateError('image empty');
    await ensureInitialized();

    final String relPath;
    if (kIsWeb) {
      // Inline data-URL stored directly in the index.
      relPath = 'data:image/png;base64,${base64Encode(bytes)}';
    } else {
      final docs = await getApplicationDocumentsDirectory();
      final safeExt =
          (ext.isNotEmpty && ext.length <= 6) ? ext.toLowerCase() : '.png';
      final name = '${_uuid.v4()}$safeExt';
      final rel = p.join(_packDirName, packId, name);
      final dest = File(p.join(docs.path, rel));
      dest.parent.createSync(recursive: true);
      await dest.writeAsBytes(bytes, flush: true);
      relPath = rel;
    }

    final packs = await _readPacksRaw();
    final i = packs.indexWhere((e) => e.id == packId);
    if (i < 0) throw StateError('pack not found');
    final p0 = packs[i];
    final emojis = List<CustomEmoji>.from(p0.emojis)
      ..removeWhere((e) => e.shortcode.toLowerCase() == sc.toLowerCase());
    emojis.add(CustomEmoji(shortcode: sc, relPath: relPath));
    packs[i] = EmojiPack(
      id: p0.id,
      name: p0.name,
      emojis: emojis,
      sourcePeerId: p0.sourcePeerId,
    );
    await _writePacks(packs);
  }

  /// Adds an emoji from an image path (native file or web OPFS/data URL).
  Future<void> addEmoji({
    required String packId,
    required String shortcode,
    required String absoluteImagePath,
  }) async {
    Uint8List? bytes;
    if (kIsWeb) {
      final pth = absoluteImagePath;
      if (pth.startsWith('data:')) {
        final comma = pth.indexOf(',');
        if (comma > 0) bytes = base64Decode(pth.substring(comma + 1));
      } else if (isWebStoredFile(pth)) {
        bytes = await readWebStoredFile(pth);
      }
    } else {
      final src = File(absoluteImagePath);
      if (src.existsSync()) bytes = await src.readAsBytes();
    }
    if (bytes == null || bytes.isEmpty) throw StateError('image missing');
    final ext = p.extension(absoluteImagePath);
    await addEmojiBytes(
      packId: packId,
      shortcode: shortcode,
      bytes: bytes,
      ext: ext.isEmpty ? '.png' : ext,
    );
  }

  String? _normalizeShortcode(String raw) {
    var s = raw.trim();
    if (s.startsWith(':') && s.endsWith(':') && s.length >= 2) {
      s = s.substring(1, s.length - 1).trim();
    }
    if (s.isEmpty || s.length > 48) return null;
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(s)) return null;
    return s;
  }

  Future<void> deleteEmoji(String packId, String shortcode) async {
    final sc = shortcode.trim().toLowerCase();
    final packs = await _readPacksRaw();
    final i = packs.indexWhere((e) => e.id == packId);
    if (i < 0) return;
    final p0 = packs[i];
    CustomEmoji? removed;
    final emojis = <CustomEmoji>[];
    for (final e in p0.emojis) {
      if (e.shortcode.toLowerCase() == sc) {
        removed = e;
      } else {
        emojis.add(e);
      }
    }
    if (removed != null && !kIsWeb && !removed.relPath.startsWith('data:')) {
      try {
        final docs = await getApplicationDocumentsDirectory();
        final f = File(p.join(docs.path, removed.relPath));
        if (f.existsSync()) await f.delete();
      } catch (_) {}
    }
    packs[i] = EmojiPack(
      id: p0.id,
      name: p0.name,
      emojis: emojis,
      sourcePeerId: p0.sourcePeerId,
    );
    await _writePacks(packs);
  }

  Future<void> deletePack(String packId) async {
    final packs = await _readPacksRaw();
    final kept = <EmojiPack>[];
    for (final e in packs) {
      if (e.id == packId) {
        if (!kIsWeb) {
          try {
            final docs = await getApplicationDocumentsDirectory();
            final dir = Directory(p.join(docs.path, _packDirName, packId));
            if (dir.existsSync()) dir.deleteSync(recursive: true);
          } catch (_) {}
        }
        continue;
      }
      kept.add(e);
    }
    await _writePacks(kept);
  }

  /// Карточка чата: [payload] с `type`/`kind` = emoji_pack, name,
  /// emojis: [{shortcode, data}] (base64). Works on web + native.
  Future<String?> installFromSharePayload(
    Map<String, dynamic> payload, {
    bool replaceByName = false,
  }) async {
    await ensureInitialized();
    final name = (payload['name'] as String?)?.trim().isNotEmpty == true
        ? (payload['name'] as String).trim()
        : 'Набор';
    final rawEmojis = (payload['emojis'] as List?) ?? const [];
    if (rawEmojis.isEmpty) return null;

    // On a re-link, drop any prior pack with the same name so we don't pile up
    // duplicate "synced" packs each time devices reconnect.
    if (replaceByName) {
      final existing = await _readPacksRaw();
      for (final p0 in existing.where((e) => e.name == name).toList()) {
        await deletePack(p0.id);
      }
    }

    final packId = await createPack(
      name: name,
      sourcePeerId: payload['sourcePeerId'] as String?,
    );
    var added = 0;
    final seen = <String>{};
    for (final e in rawEmojis) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final scRaw = (m['shortcode'] as String? ?? '').trim();
      final b64 = (m['data'] as String? ?? m['imageBase64'] as String? ?? '')
          .trim();
      if (scRaw.isEmpty || b64.isEmpty) continue;
      final norm = _normalizeShortcode(scRaw);
      if (norm == null || !seen.add(norm)) continue;
      Uint8List bytes;
      try {
        bytes = base64Decode(b64);
      } catch (_) {
        continue;
      }
      if (bytes.isEmpty) continue;
      // Animated emoji arrive as GIF — keep the right extension on native so the
      // file decodes (and animates) correctly.
      final isGif = bytes.length > 3 &&
          bytes[0] == 0x47 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46;
      try {
        await addEmojiBytes(
          packId: packId,
          shortcode: norm,
          bytes: bytes,
          ext: isGif ? '.gif' : '.png',
        );
        added++;
      } catch (_) {}
    }
    if (added == 0) {
      await deletePack(packId);
      return null;
    }
    return packId;
  }

  /// Авто-импорт эмодзи от пира (служебный payload relay blob).
  ///
  /// Groups incoming emoji by the SENDER's own pack name (carried per-emoji
  /// as `'pack'`, see EmojiPackDmService._buildPayloadFromShortcodes) instead
  /// of dumping everything from one peer into a single undifferentiated
  /// "Автоимпорт" bucket — e.g. emoji from their "Смайлы" pack land in a
  /// "Смайлы" pack here too, so it's obvious what you're looking at. Falls
  /// back to a neutral name only if the sender's pack couldn't be resolved.
  Future<int> installFromAutoPayload(
    Map<String, dynamic> payload, {
    required String sourcePeerId,
  }) async {
    await ensureInitialized();
    final rawEmojis = (payload['emojis'] as List?) ?? const [];
    if (rawEmojis.isEmpty) return 0;

    final packs = await _readPacksRaw();
    final resolvedPackIds = <String, String>{};

    Future<String> packIdFor(String name) async {
      final cached = resolvedPackIds[name];
      if (cached != null) return cached;
      for (final p0 in packs) {
        if (p0.sourcePeerId == sourcePeerId && p0.name == name) {
          resolvedPackIds[name] = p0.id;
          return p0.id;
        }
      }
      final id = await createPack(name: name, sourcePeerId: sourcePeerId);
      resolvedPackIds[name] = id;
      return id;
    }

    var n = 0;
    for (final e in rawEmojis) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final scRaw = (m['shortcode'] as String? ?? '').trim();
      final b64 = (m['data'] as String? ?? '').trim();
      if (scRaw.isEmpty || b64.isEmpty) continue;
      final norm = _normalizeShortcode(scRaw);
      if (norm == null) continue;
      Uint8List bytes;
      try {
        bytes = base64Decode(b64);
      } catch (_) {
        continue;
      }
      if (bytes.isEmpty) continue;
      final packName = (m['pack'] as String?)?.trim();
      final targetName =
          (packName != null && packName.isNotEmpty) ? packName : 'Из чата';
      try {
        final packId = await packIdFor(targetName);
        await addEmojiBytes(packId: packId, shortcode: norm, bytes: bytes);
        n++;
      } catch (_) {}
    }
    if (n > 0) {
      refreshIndexSync();
      version.value++;
    }
    return n;
  }

  /// Builds a share payload (base64 images) for all packs — used to sync custom
  /// emoji to a linked device. Returns one map per pack.
  Future<List<Map<String, dynamic>>> exportAllPacksAsPayloads() async {
    await warmIndex(); // ensure _shortcodeToRef is populated before reading bytes
    final packs = await _readPacksRaw();
    final out = <Map<String, dynamic>>[];
    for (final pack in packs) {
      final emojis = <Map<String, dynamic>>[];
      for (final e in pack.emojis) {
        final bytes = await readEmojiBytesByShortcode(e.shortcode);
        if (bytes == null || bytes.isEmpty) continue;
        emojis.add({'shortcode': e.shortcode, 'data': base64Encode(bytes)});
      }
      if (emojis.isEmpty) continue;
      out.add({
        'name': pack.name,
        'emojis': emojis,
        if (pack.sourcePeerId != null) 'sourcePeerId': pack.sourcePeerId,
      });
    }
    return out;
  }
}
