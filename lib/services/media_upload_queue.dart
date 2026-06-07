import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'image_service.dart';
import 'relay_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import '../models/chat_message.dart';

/// Status of an upload task.
enum UploadStatus { pending, uploading, done, failed }

/// A single media upload task.
class UploadTask {
  final String id;
  final String msgId;
  final String filePath;
  final String recipientKey;
  final String fromId;
  final bool isVoice;
  final bool isVideo;
  final bool isSquare;
  final bool isFile;
  final bool isSticker;
  final String? fileName;
  UploadStatus status;
  int retryCount;

  UploadTask({
    required this.id,
    required this.msgId,
    required this.filePath,
    required this.recipientKey,
    required this.fromId,
    this.isVoice = false,
    this.isVideo = false,
    this.isSquare = false,
    this.isFile = false,
    this.isSticker = false,
    this.fileName,
    this.status = UploadStatus.pending,
    this.retryCount = 0,
  });
}

/// SQLite-backed background media upload queue.
///
/// • Enqueue any media file for relay delivery.
/// • Queue is persisted across app restarts.
/// • Resumes automatically when relay reconnects.
/// • Progress tracked via [progressMap] ValueNotifier.
class MediaUploadQueue {
  MediaUploadQueue._();
  static final MediaUploadQueue instance = MediaUploadQueue._();

  Database? _db;
  bool _processing = false;
  bool _relayListenersAttached = false;

  /// Per-msgId upload progress (0.0 – 1.0). Key is removed when upload completes.
  final ValueNotifier<Map<String, double>> progressMap =
      ValueNotifier(<String, double>{});

  /// Called when a task completes successfully. Use to update message status in UI.
  void Function(String msgId)? onTaskCompleted;

  /// iOS Dynamic Island: прогресс при отправке «крупного» медиа (см. порог ниже).
  void Function(String label, double progress)? onLiveActivityMediaProgress;

  /// Порог размера **сжатых** данных для показа Live Activity (~100 KB).
  static const kLiveActivityMinCompressedBytes = 100 * 1024;

  /// Max blob size for single relay message (~100 KB compressed).
  /// All files larger than this are automatically split into chunks for reliable delivery.
  static const _kMaxBlobBytes = 100 * 1024;

  /// Relay chunk size for large media.
  /// 500 KB per chunk — sent as relay `blob` type (single base64, ~667 KB on wire),
  /// safely under the relay server's 10 MB raw-message limit.
  /// A 13 MB file becomes ~26 chunks @ 50 ms = ~1.3 s.
  static const _kRelayChunkBytes = 500 * 1024;

  /// Max retry attempts before marking a task failed.
  static const _kMaxRetries = 5;

  Future<void> init() async {
    final dbDir = await getDatabasesPath();
    final dbPath = p.join(dbDir, 'rlink_upload_queue.db');
    _db = await openDatabase(
      dbPath,
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE upload_queue (
            id         TEXT    PRIMARY KEY,
            msgId      TEXT    NOT NULL,
            filePath   TEXT    NOT NULL,
            recipientKey TEXT  NOT NULL,
            fromId     TEXT    NOT NULL,
            isVoice    INTEGER NOT NULL DEFAULT 0,
            isVideo    INTEGER NOT NULL DEFAULT 0,
            isSquare   INTEGER NOT NULL DEFAULT 0,
            isFile     INTEGER NOT NULL DEFAULT 0,
            isSticker  INTEGER NOT NULL DEFAULT 0,
            fileName   TEXT,
            status     INTEGER NOT NULL DEFAULT 0,
            retryCount INTEGER NOT NULL DEFAULT 0,
            createdAt  INTEGER NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute(
              'ALTER TABLE upload_queue ADD COLUMN isSticker INTEGER NOT NULL DEFAULT 0',
            );
          } catch (e) {
            debugPrint('[UploadQueue] migrate isSticker: $e');
          }
        }
      },
    );
    // Сброс залипших задач от прошлой версии: всё, что висит uploading или
    // упёрлось в retry-лимит, сбрасываем в pending с retryCount=0, чтобы
    // фикс race-condition-а смог их доставить с чистого листа.
    try {
      final reset = await _db!.rawUpdate(
        'UPDATE upload_queue SET status = ?, retryCount = 0 '
        'WHERE status = ? OR (status = ? AND retryCount >= ?)',
        [
          UploadStatus.pending.index,
          UploadStatus.uploading.index,
          UploadStatus.failed.index,
          _kMaxRetries,
        ],
      );
      if (reset > 0) {
        debugPrint('[UploadQueue] Reset $reset stuck/failed tasks to pending');
      }
    } catch (e) {
      debugPrint('[UploadQueue] Reset stuck tasks failed: $e');
    }
    if (!_relayListenersAttached) {
      _relayListenersAttached = true;
      RelayService.instance.state.addListener(_processOnRelaySignal);
      RelayService.instance.presenceVersion.addListener(_processOnRelaySignal);
    }
    debugPrint('[UploadQueue] Initialized');
  }

  void _processOnRelaySignal() {
    if (RelayService.instance.isConnected) {
      unawaited(processQueue());
    }
  }

  /// Add a media file to the upload queue.
  /// The file must already exist at [filePath] before calling this.
  Future<void> enqueue({
    required String msgId,
    required String filePath,
    required String recipientKey,
    required String fromId,
    bool isVoice = false,
    bool isVideo = false,
    bool isSquare = false,
    bool isFile = false,
    bool isSticker = false,
    String? fileName,
  }) async {
    final db = _db;
    if (db == null) return;
    await db.insert(
      'upload_queue',
      {
        'id': const Uuid().v4(),
        'msgId': msgId,
        'filePath': filePath,
        'recipientKey': recipientKey,
        'fromId': fromId,
        'isVoice': isVoice ? 1 : 0,
        'isVideo': isVideo ? 1 : 0,
        'isSquare': isSquare ? 1 : 0,
        'isFile': isFile ? 1 : 0,
        'isSticker': isSticker ? 1 : 0,
        'fileName': fileName,
        'status': UploadStatus.pending.index,
        'retryCount': 0,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    debugPrint(
        '[UploadQueue] Enqueued msgId=$msgId for ${recipientKey.substring(0, 8)}');
    // Start processing immediately if relay is ready
    unawaited(processQueue());
  }

  /// Process all pending tasks. Safe to call multiple times — debounced via [_processing].
  /// Loops until no more pending tasks so tasks enqueued during processing are also handled.
  Future<void> processQueue() async {
    if (_processing) return;
    if (!RelayService.instance.isConnected) return;
    _processing = true;
    try {
      final db = _db;
      if (db == null) return;

      final rows = await db.query(
        'upload_queue',
        where: 'status IN (?, ?) AND retryCount < ?',
        whereArgs: [
          UploadStatus.pending.index,
          UploadStatus.failed.index,
          _kMaxRetries,
        ],
        orderBy: 'createdAt ASC',
      );
      if (rows.isEmpty) return;

      debugPrint('[UploadQueue] Processing ${rows.length} pending tasks');
      for (final row in rows) {
        if (!RelayService.instance.isConnected) break;
        await _processTask(_taskFromRow(row));
      }
    } finally {
      _processing = false;
    }
  }

  Future<void> _processTask(UploadTask task) async {
    final db = _db;
    if (db == null) return;

    final label = _liveActivityLabel(task);
    var showIsland = false;
    var transferAccepted = false;
    final previousDeliveryFailed = RelayService.instance.onDeliveryFailed;

    // Skip if file no longer exists
    if (!File(task.filePath).existsSync()) {
      debugPrint(
          '[UploadQueue] File missing for ${task.msgId}, marking failed');
      await db.update(
        'upload_queue',
        {'status': UploadStatus.failed.index},
        where: 'id = ?',
        whereArgs: [task.id],
      );
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        task.msgId,
        MessageStatus.failed,
      );
      return;
    }

    if (RelayService.instance.isPeerKnownOffline(task.recipientKey)) {
      debugPrint('[UploadQueue] Recipient offline for ${task.msgId}; waiting');
      await db.update(
        'upload_queue',
        {'status': UploadStatus.pending.index},
        where: 'id = ?',
        whereArgs: [task.id],
      );
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        task.msgId,
        MessageStatus.sending,
      );
      _setProgress(task.msgId, 0);
      return;
    }

    final recipientX25519 = await _recipientX25519(task.recipientKey);
    if (recipientX25519 == null || recipientX25519.isEmpty) {
      final shortKey = task.recipientKey.length > 8
          ? task.recipientKey.substring(0, 8)
          : task.recipientKey;
      debugPrint('[UploadQueue] Missing X25519 for $shortKey; waiting');
      await db.update(
        'upload_queue',
        {'status': UploadStatus.pending.index},
        where: 'id = ?',
        whereArgs: [task.id],
      );
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        task.msgId,
        MessageStatus.sending,
      );
      _setProgress(task.msgId, 0);
      return;
    }

    // Mark uploading
    await db.update(
      'upload_queue',
      {'status': UploadStatus.uploading.index},
      where: 'id = ?',
      whereArgs: [task.id],
    );
    _setProgress(task.msgId, 0.01);

    bool recipientOffline = false;
    void onDeliveryFailed(String key) {
      previousDeliveryFailed?.call(key);
      if (key.toLowerCase() == task.recipientKey.toLowerCase()) {
        recipientOffline = true;
      }
    }

    RelayService.instance.onDeliveryFailed = onDeliveryFailed;

    try {
      final bytes = await File(task.filePath).readAsBytes();
      final compressed = ImageService.instance.compress(bytes);
      final sealed = await CryptoService.instance.sealMediaPayload(
        plaintext: compressed,
        recipientX25519KeyBase64: recipientX25519,
      );
      showIsland = compressed.length >= kLiveActivityMinCompressedBytes;
      if (showIsland) {
        onLiveActivityMediaProgress?.call(label, 0.06);
      }

      if (sealed.length <= _kMaxBlobBytes) {
        // ── Single blob send ──────────────────────────────────────
        if (showIsland) {
          onLiveActivityMediaProgress?.call(label, 0.12);
        }
        await RelayService.instance.sendBlob(
          recipientKey: task.recipientKey,
          fromId: task.fromId,
          msgId: task.msgId,
          compressedData: sealed,
          isVoice: task.isVoice,
          isVideo: task.isVideo,
          isSquare: task.isSquare,
          isFile: task.isFile,
          isSticker: task.isSticker,
          fileName: task.fileName,
        );
        await Future.delayed(const Duration(milliseconds: 300));
        if (recipientOffline) {
          await _requeueAfterLiveDeliveryFailure(task);
          return;
        }
        if (showIsland) {
          onLiveActivityMediaProgress?.call(label, 0.9);
        }
        _setProgress(task.msgId, 0.99);
      } else {
        // ── Chunked send for large files ──────────────────────────
        final total = (sealed.length / _kRelayChunkBytes).ceil();
        debugPrint('[UploadQueue] Large file: $total chunks for ${task.msgId}');
        for (var i = 0; i < total; i++) {
          if (!RelayService.instance.isConnected) {
            // Relay gone — requeue and stop (resume on reconnect).
            await db.update(
              'upload_queue',
              {'status': UploadStatus.pending.index},
              where: 'id = ?',
              whereArgs: [task.id],
            );
            _setProgress(task.msgId, 0);
            return;
          }
          final offset = i * _kRelayChunkBytes;
          final end = (offset + _kRelayChunkBytes).clamp(0, sealed.length);
          final chunk = Uint8List.sublistView(sealed, offset, end);
          await RelayService.instance.sendBlobChunk(
            recipientKey: task.recipientKey,
            fromId: task.fromId,
            msgId: task.msgId,
            chunkIdx: i,
            chunkTotal: total,
            chunkData: chunk,
            isVoice: task.isVoice,
            isVideo: task.isVideo,
            isSquare: task.isSquare,
            isFile: task.isFile,
            isSticker: task.isSticker,
            fileName: task.fileName,
          );
          await Future.delayed(const Duration(milliseconds: 20));
          if (recipientOffline) {
            await _requeueAfterLiveDeliveryFailure(task);
            return;
          }
          final frac = (i + 1) / total;
          _setProgress(task.msgId, frac >= 1 ? 0.99 : frac);
          if (showIsland) {
            onLiveActivityMediaProgress?.call(label, frac >= 1 ? 0.99 : frac);
          }
        }
        await Future.delayed(const Duration(milliseconds: 300));
        if (recipientOffline) {
          await _requeueAfterLiveDeliveryFailure(task);
          return;
        }
        _setProgress(task.msgId, 0.99);
      }

      // Bytes reached an online recipient socket. Keep the task in uploading
      // until the recipient saves the media and sends the app-level ACK.
      debugPrint('[UploadQueue] Awaiting recipient ACK: ${task.msgId}');
      transferAccepted = true;
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        task.msgId,
        MessageStatus.sent,
      );
      onTaskCompleted?.call(task.msgId);
    } catch (e) {
      debugPrint('[UploadQueue] Task ${task.msgId} failed: $e');
      final nextRetry = task.retryCount + 1;
      final failed = nextRetry >= _kMaxRetries;
      await db.update(
        'upload_queue',
        {
          'status':
              failed ? UploadStatus.failed.index : UploadStatus.pending.index,
          'retryCount': nextRetry,
        },
        where: 'id = ?',
        whereArgs: [task.id],
      );
      _setProgress(task.msgId, 0);
      if (failed) {
        await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
          task.msgId,
          MessageStatus.failed,
        );
      }
    } finally {
      if (showIsland) {
        onLiveActivityMediaProgress?.call(label, transferAccepted ? 0.99 : 0);
      }
      // Clear per-task delivery-fail listener
      if (RelayService.instance.onDeliveryFailed == onDeliveryFailed) {
        RelayService.instance.onDeliveryFailed = previousDeliveryFailed;
      }
    }
  }

  Future<void> _requeueAfterLiveDeliveryFailure(UploadTask task) async {
    final db = _db;
    if (db == null) return;
    final nextRetry = task.retryCount + 1;
    final failed = nextRetry >= _kMaxRetries;
    await db.update(
      'upload_queue',
      {
        'status':
            failed ? UploadStatus.failed.index : UploadStatus.pending.index,
        'retryCount': nextRetry,
      },
      where: 'id = ?',
      whereArgs: [task.id],
    );
    _setProgress(task.msgId, 0);
    await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
      task.msgId,
      failed ? MessageStatus.failed : MessageStatus.sending,
    );
    debugPrint('[UploadQueue] Live delivery failed for ${task.msgId}; '
        '${failed ? 'retry limit reached' : 'requeued'}');
  }

  String _liveActivityLabel(UploadTask t) {
    if (t.isVideo) return t.isSquare ? 'Видео' : 'Видео';
    if (t.isVoice) return 'Голосовое';
    if (t.isFile) {
      final n = t.fileName;
      if (n != null && n.isNotEmpty) {
        return n.length > 28 ? '${n.substring(0, 28)}…' : n;
      }
      return 'Файл';
    }
    return 'Фото';
  }

  Future<String?> _recipientX25519(String recipientKey) async {
    final key = recipientKey.trim().toLowerCase();
    final relayKey = RelayService.instance.getPeerX25519Key(key);
    if (relayKey != null && relayKey.isNotEmpty) return relayKey;
    final contact = await ChatStorageService.instance.getContact(key);
    final stored = contact?.x25519Key?.trim();
    return stored != null && stored.isNotEmpty ? stored : null;
  }

  void _setProgress(String msgId, double progress) {
    final map = Map<String, double>.from(progressMap.value);
    if (progress >= 1.0) {
      map.remove(msgId);
    } else {
      map[msgId] = progress;
    }
    progressMap.value = map;
  }

  UploadTask _taskFromRow(Map<String, dynamic> row) => UploadTask(
        id: row['id'] as String,
        msgId: row['msgId'] as String,
        filePath: row['filePath'] as String,
        recipientKey: row['recipientKey'] as String,
        fromId: row['fromId'] as String,
        isVoice: (row['isVoice'] as int) == 1,
        isVideo: (row['isVideo'] as int) == 1,
        isSquare: (row['isSquare'] as int) == 1,
        isFile: (row['isFile'] as int) == 1,
        isSticker: (row['isSticker'] as int?) == 1,
        fileName: row['fileName'] as String?,
        status: UploadStatus.values[row['status'] as int],
        retryCount: row['retryCount'] as int,
      );

  /// Current progress for a given msgId (0.0 – 1.0, or 0.0 if not uploading).
  double progressFor(String msgId) => progressMap.value[msgId] ?? 0;

  /// True while this msgId is being uploaded.
  bool isUploading(String msgId) => progressMap.value.containsKey(msgId);

  /// Marks a media task as fully delivered after the recipient app-level ACK.
  Future<void> markDelivered(String msgId) async {
    final db = _db;
    if (db == null) return;
    final n = await db.update(
      'upload_queue',
      {'status': UploadStatus.done.index},
      where: 'msgId = ?',
      whereArgs: [msgId],
    );
    if (n > 0) {
      _setProgress(msgId, 1.0);
      debugPrint('[UploadQueue] Delivered ACK: $msgId');
    }
  }

  /// Remove completed tasks older than [maxAge].
  Future<void> cleanUp({Duration maxAge = const Duration(days: 7)}) async {
    final db = _db;
    if (db == null) return;
    final cutoff = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    final deleted = await db.delete(
      'upload_queue',
      where: 'status = ? AND createdAt < ?',
      whereArgs: [UploadStatus.done.index, cutoff],
    );
    if (deleted > 0) {
      debugPrint('[UploadQueue] Cleaned up $deleted completed tasks');
    }
  }

  /// Removes all queued tasks (used on full app reset).
  Future<void> clearAll() async {
    final db = _db;
    if (db == null) return;
    await db.delete('upload_queue');
    progressMap.value = {};
    debugPrint('[UploadQueue] Cleared all tasks');
  }

  /// Отменяет все задачи загрузки для сообщения и убирает его прогресс из UI.
  Future<bool> cancelTaskForMsgId(String msgId) async {
    final db = _db;
    if (db == null) return false;
    final n = await db.delete(
      'upload_queue',
      where: 'msgId = ?',
      whereArgs: [msgId],
    );
    final map = Map<String, double>.from(progressMap.value)..remove(msgId);
    progressMap.value = map;
    if (n > 0) {
      debugPrint('[UploadQueue] Canceled $n task(s) for $msgId');
      return true;
    }
    return false;
  }

  /// Сброс задачи(ч) по [msgId] в pending — после ошибки или ручного «Повторить».
  Future<bool> retryTaskForMsgId(String msgId) async {
    final db = _db;
    if (db == null) return false;
    final n = await db.update(
      'upload_queue',
      {
        'status': UploadStatus.pending.index,
        'retryCount': 0,
      },
      where: 'msgId = ?',
      whereArgs: [msgId],
    );
    if (n > 0) {
      unawaited(processQueue());
      return true;
    }
    return false;
  }

  /// All pending task count (for UI badges).
  Future<int> pendingCount() async {
    final db = _db;
    if (db == null) return 0;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM upload_queue WHERE status IN (?, ?)',
      [UploadStatus.pending.index, UploadStatus.uploading.index],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }
}
