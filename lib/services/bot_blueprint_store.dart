import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/bot_blueprint.dart';
import '../utils/web_file_store.dart';

/// Локальное хранилище черновиков ботов из no-code конструктора.
///
/// Живёт в SharedPreferences; на web дополнительно зеркалится в OPFS
/// (`opfs://rlink/bot_blueprints.json`), потому что localStorage браузер
/// вытесняет между сессиями — та же схема, что для Google-аккаунтов Drive.
class BotBlueprintStore {
  BotBlueprintStore._();
  static final BotBlueprintStore instance = BotBlueprintStore._();

  static const _prefsKey = 'bot_blueprints_v1';
  static const _opfsName = 'bot_blueprints.json';
  static const _opfsPath = 'opfs://rlink/bot_blueprints.json';

  List<BotBlueprint>? _cache;

  Future<List<BotBlueprint>> load() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    var raw = prefs.getString(_prefsKey);
    if ((raw == null || raw.isEmpty) && kIsWeb) {
      raw = await _readOpfs();
      if (raw != null && raw.isNotEmpty) {
        await prefs.setString(_prefsKey, raw); // восстановить в prefs
      }
    }
    _cache = _decode(raw);
    return _cache!;
  }

  Future<BotBlueprint?> getById(String id) async {
    final list = await load();
    for (final b in list) {
      if (b.id == id) return b;
    }
    return null;
  }

  Future<void> save(BotBlueprint bp) async {
    final list = await load();
    bp.updatedAt = DateTime.now();
    final idx = list.indexWhere((b) => b.id == bp.id);
    if (idx >= 0) {
      list[idx] = bp;
    } else {
      list.add(bp);
    }
    await _persist(list);
  }

  Future<void> delete(String id) async {
    final list = await load();
    list.removeWhere((b) => b.id == id);
    await _persist(list);
  }

  String newId() =>
      'bp_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  // ── внутреннее ────────────────────────────────────────────────────────────

  List<BotBlueprint> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return <BotBlueprint>[];
    try {
      final j = jsonDecode(raw);
      if (j is List) {
        return j
            .whereType<Map>()
            .map((m) => BotBlueprint.fromJson(Map<String, dynamic>.from(m)))
            .toList();
      }
    } catch (_) {}
    return <BotBlueprint>[];
  }

  Future<void> _persist(List<BotBlueprint> list) async {
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _cache = list;
    final raw = jsonEncode(list.map((b) => b.toJson()).toList());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, raw);
    if (kIsWeb) await _writeOpfs(raw);
  }

  Future<String?> _readOpfs() async {
    try {
      final bytes = await readWebStoredFile(_opfsPath);
      if (bytes == null || bytes.isEmpty) return null;
      return utf8.decode(bytes);
    } catch (e) {
      debugPrint('[RLINK][BotBuilder] OPFS read failed: $e');
      return null;
    }
  }

  Future<void> _writeOpfs(String raw) async {
    try {
      await writeWebStoredFile(
        fileName: _opfsName,
        bytes: Uint8List.fromList(utf8.encode(raw)),
        mimeType: 'application/json',
      );
    } catch (e) {
      debugPrint('[RLINK][BotBuilder] OPFS mirror failed: $e');
    }
  }
}
