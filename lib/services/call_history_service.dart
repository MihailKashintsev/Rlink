import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_storage_service.dart';
import '../models/chat_message.dart';

/// Одна запись в журнале звонков (локально на устройстве).
class CallHistoryEntry {
  final String id;
  final String peerId;
  final String peerDisplayName;
  final int endedAtMs;
  final int durationMs;
  final bool incoming;
  final bool video;
  final String? recordingPath;
  final String? transcript;
  final String?
      transcriptSpeakerLabels; // JSON: [{"speaker":"me"/"peer","text":"..."},...]

  const CallHistoryEntry({
    required this.id,
    required this.peerId,
    required this.peerDisplayName,
    required this.endedAtMs,
    required this.durationMs,
    required this.incoming,
    required this.video,
    this.recordingPath,
    this.transcript,
    this.transcriptSpeakerLabels,
  });

  DateTime get endedAt =>
      DateTime.fromMillisecondsSinceEpoch(endedAtMs, isUtc: false);

  Duration get duration => Duration(milliseconds: durationMs);

  Map<String, dynamic> toJson() => {
        'id': id,
        'peerId': peerId,
        'peerDisplayName': peerDisplayName,
        'endedAtMs': endedAtMs,
        'durationMs': durationMs,
        'incoming': incoming,
        'video': video,
        'recordingPath': recordingPath,
        'transcript': transcript,
        'transcriptSpeakerLabels': transcriptSpeakerLabels,
      };

  factory CallHistoryEntry.fromJson(Map<String, dynamic> m) {
    return CallHistoryEntry(
      id: m['id'] as String? ?? '',
      peerId: (m['peerId'] as String? ?? '').trim().toLowerCase(),
      peerDisplayName: m['peerDisplayName'] as String? ?? '',
      endedAtMs: (m['endedAtMs'] as num?)?.toInt() ?? 0,
      durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
      incoming: m['incoming'] == true,
      video: m['video'] == true,
      recordingPath: m['recordingPath'] as String?,
      transcript: m['transcript'] as String?,
      transcriptSpeakerLabels: m['transcriptSpeakerLabels'] as String?,
    );
  }
}

/// Локальная история звонков (до [_kMaxEntries] записей).
class CallHistoryService {
  CallHistoryService._();
  static final CallHistoryService instance = CallHistoryService._();

  static const int _kMaxEntries = 200;
  static const String _prefsKey = 'rlink_call_history_v1';

  final ValueNotifier<int> version = ValueNotifier(0);
  List<CallHistoryEntry> _entries = [];
  Future<void>? _ready;

  List<CallHistoryEntry> get entries => List.unmodifiable(_entries);

  Future<void> _ensureReady() async {
    if (_ready != null) {
      await _ready;
      return;
    }
    _ready ??= () async {
      await _load();
      version.value++;
    }();
    await _ready;
  }

  /// Подгрузить файл истории (для экрана вкладки).
  Future<void> ensureLoaded() => _ensureReady();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) {
      _entries = [];
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        _entries = [];
        return;
      }
      _entries = decoded
          .whereType<Map>()
          .map((e) => CallHistoryEntry.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.peerId.length >= 8)
          .toList();
    } catch (e) {
      debugPrint('[CallHistory] load failed: $e');
      _entries = [];
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(_entries.map((e) => e.toJson()).toList());
      await prefs.setString(_prefsKey, encoded);
    } catch (e) {
      debugPrint('[CallHistory] save failed: $e');
    }
  }

  static Future<String> _resolveDisplayName(String peerId) async {
    final c = await ChatStorageService.instance.getContact(peerId);
    final n = c?.nickname.trim() ?? '';
    if (n.isNotEmpty) return n;
    if (peerId.length >= 12) return '${peerId.substring(0, 8)}…';
    return peerId;
  }

  /// Завершённый или прерванный звонок ([CallService._cleanup]).
  Future<void> recordCallEnded({
    required String peerId,
    required Duration duration,
    required bool incoming,
    required bool video,
    String? recordingPath,
  }) async {
    if (peerId.trim().length < 8) return;
    final normalized = peerId.trim().toLowerCase();
    await _ensureReady();
    final name = await _resolveDisplayName(normalized);
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = '${now}_$normalized';
    final entry = CallHistoryEntry(
      id: id,
      peerId: normalized,
      peerDisplayName: name,
      endedAtMs: now,
      durationMs: duration.inMilliseconds.clamp(0, 86400000 * 1000),
      incoming: incoming,
      video: video,
      recordingPath: recordingPath,
    );
    _entries.insert(0, entry);
    while (_entries.length > _kMaxEntries) {
      _entries.removeLast();
    }
    version.value++;
    await _save();
    await _saveChatCallMessage(entry);
  }

  /// Сохранить расшифровку для записи звонка.
  Future<void> setTranscript(String entryId, String transcript,
      {String? speakerLabels}) async {
    await _ensureReady();
    final idx = _entries.indexWhere((e) => e.id == entryId);
    if (idx < 0) return;
    final old = _entries[idx];
    _entries[idx] = CallHistoryEntry(
      id: old.id,
      peerId: old.peerId,
      peerDisplayName: old.peerDisplayName,
      endedAtMs: old.endedAtMs,
      durationMs: old.durationMs,
      incoming: old.incoming,
      video: old.video,
      recordingPath: old.recordingPath,
      transcript: transcript,
      transcriptSpeakerLabels: speakerLabels,
    );
    version.value++;
    await _save();
  }

  Future<void> _saveChatCallMessage(CallHistoryEntry entry) async {
    try {
      final title = entry.video ? 'Видеозвонок' : 'Звонок';
      final dur = entry.duration;
      final durationText = dur.inSeconds <= 0
          ? 'не состоялся'
          : '${dur.inMinutes.remainder(60).toString().padLeft(2, '0')}:${dur.inSeconds.remainder(60).toString().padLeft(2, '0')}';
      await ChatStorageService.instance.saveMessage(
        ChatMessage(
          id: 'call_${entry.id}',
          peerId: entry.peerId,
          text: '$title • $durationText',
          isOutgoing: !entry.incoming,
          timestamp: entry.endedAt,
          status: MessageStatus.sent,
          invitePayloadJson: jsonEncode({
            'kind': 'call_history',
            'callId': entry.id,
            'video': entry.video,
            'incoming': entry.incoming,
            'endedAtMs': entry.endedAtMs,
            'durationMs': entry.durationMs,
            if (entry.recordingPath != null)
              'recordingPath': entry.recordingPath,
          }),
        ),
      );
    } catch (e) {
      debugPrint('[CallHistory] chat message save failed: $e');
    }
  }

  Future<void> recordRejectedIncoming({
    required String peerId,
    required bool video,
  }) async {
    await recordCallEnded(
      peerId: peerId,
      duration: Duration.zero,
      incoming: true,
      video: video,
    );
  }
}
