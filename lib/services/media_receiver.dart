import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import 'channel_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'gossip_router.dart';
import 'group_service.dart';
import 'image_service.dart';
import 'story_service.dart';

/// Унифицированный приёмник медиа: единый pipeline для BLE-чанков и relay-blob.
class MediaReceiver {
  MediaReceiver._();
  static final MediaReceiver instance = MediaReceiver._();

  final _incomingMessageController = StreamController<ChatMessage>.broadcast();
  Stream<ChatMessage> get incomingMessages => _incomingMessageController.stream;

  void Function(String peerId, String body)? onNotify;

  /// Собрать и сохранить медиа, определить тип (DM/канал/группа/история) и доставить.
  Future<void> assembleAndDeliver(
      {required String fromId, required String msgId}) async {
    final img = ImageService.instance;
    final isAvatar = img.isAvatarAssembly(msgId);
    final isVoice = img.isVoiceAssembly(msgId);
    final isVideo = img.isVideoAssembly(msgId);
    final isSquare = img.isSquareAssembly(msgId);
    final isFile = img.isFileAssembly(msgId);
    final isSticker = img.isStickerAssembly(msgId);
    final isChannelPost = img.isChannelPostAssembly(msgId);
    final fileName = img.assemblyFileName(msgId);
    final viewOnce = img.isViewOnceAssembly(msgId);
    final ffId = img.assemblyForwardFromId(msgId);
    final ffNick = img.assemblyForwardFromNick(msgId);
    final ffCh = img.assemblyForwardFromChannelId(msgId);
    final senderKey = img.assemblyFromId(msgId).isNotEmpty
        ? img.assemblyFromId(msgId)
        : fromId;

    // Service media (banner, music, channel visuals)
    if (await _tryServiceMedia(msgId, senderKey)) return;

    // Avatar
    if (isAvatar) {
      final path = await img.assembleAndSave(msgId, forContactKey: senderKey);
      if (path != null) {
        img.markCompleted(msgId);
        await ChatStorageService.instance
            .updateContactAvatarImage(senderKey, path);
      }
      return;
    }

    // Channel post / comment
    if (isChannelPost || await ChannelService.instance.getPost(msgId) != null) {
      await _deliverToChannelPost(msgId, isVoice, isVideo, isFile, fileName);
      return;
    }
    if (await ChannelService.instance.getComment(msgId) != null) {
      await _deliverToChannelComment(msgId, isVoice, isVideo, isFile, fileName);
      return;
    }

    // Group
    if (await GroupService.instance.getMessage(msgId) != null) {
      await _deliverToGroup(msgId, isVideo, isSquare);
      return;
    }

    // Story
    if (await _tryStory(msgId)) return;

    // Direct message
    await _deliverToDm(
      fromId: senderKey,
      msgId: msgId,
      isVoice: isVoice,
      isVideo: isVideo,
      isSquare: isSquare,
      isFile: isFile,
      isSticker: isSticker,
      fileName: fileName,
      viewOnce: viewOnce,
      forwardFromId: ffId,
      forwardFromNick: ffNick,
      forwardFromChannelId: ffCh,
    );
  }

  Future<bool> _tryServiceMedia(String msgId, String senderKey) async {
    final img = ImageService.instance;
    if (msgId.startsWith('banner_')) {
      final path = await img.assembleAndSave(msgId,
          forContactKey: '${senderKey}_banner');
      if (path != null) {
        img.markCompleted(msgId);
        final c = await ChatStorageService.instance.getContact(senderKey);
        if (c != null) {
          await ChatStorageService.instance.saveContact(
              c.copyWith(bannerImagePath: path, setBannerImagePath: true));
        }
      }
      return true;
    }
    if (msgId.startsWith('profile_music_')) {
      final path = await img.assembleAndSaveProfileMusic(msgId, senderKey);
      if (path != null) {
        img.markCompleted(msgId);
        final c = await ChatStorageService.instance.getContact(senderKey);
        if (c != null) {
          await ChatStorageService.instance.saveContact(
              c.copyWith(profileMusicPath: path, setProfileMusicPath: true));
        }
      }
      return true;
    }
    if (msgId.startsWith('chbn_')) {
      final path = await img.assembleAndSave(msgId);
      if (path != null) {
        img.markCompleted(msgId);
        await ChannelService.instance.applyChannelBannerFromNetwork(
            msgId.substring('chbn_'.length), path);
      }
      return true;
    }
    if (msgId.startsWith('chav_')) {
      final path = await img.assembleAndSave(msgId);
      if (path != null) {
        img.markCompleted(msgId);
        await ChannelService.instance.applyChannelAvatarFromNetwork(
            msgId.substring('chav_'.length), path);
      }
      return true;
    }
    return false;
  }

  Future<void> _deliverToChannelPost(String msgId, bool isVoice, bool isVideo,
      bool isFile, String? fileName) async {
    final img = ImageService.instance;
    if (isVoice) {
      final p = await img.assembleAndSaveVoice(msgId);
      if (p != null) {
        img.markCompleted(msgId);
        await ChannelService.instance
            .applyAssembledPostMedia(postId: msgId, voicePath: p);
      }
    } else if (isFile) {
      final p = await img.assembleAndSaveFile(msgId);
      if (p != null) {
        img.markCompleted(msgId);
        final sz = kIsWeb ? _dataUriSize(p) : await File(p).length();
        await ChannelService.instance.applyAssembledPostMedia(
            postId: msgId, filePath: p, fileName: fileName, fileSize: sz);
      }
    } else if (isVideo) {
      final p = await img.assembleAndSaveVideo(msgId);
      if (p != null) {
        img.markCompleted(msgId);
        await ChannelService.instance
            .applyAssembledPostMedia(postId: msgId, videoPath: p);
      }
    } else {
      final p = await img.assembleAndSave(msgId);
      if (p != null) {
        img.markCompleted(msgId);
        await ChannelService.instance
            .applyAssembledPostMedia(postId: msgId, imagePath: p);
      }
    }
  }

  Future<void> _deliverToChannelComment(String msgId, bool isVoice,
      bool isVideo, bool isFile, String? fileName) async {
    final img = ImageService.instance;
    if (isVoice) {
      final p = await img.assembleAndSaveVoice(msgId);
      if (p != null) {
        img.markCompleted(msgId);
        await ChannelService.instance
            .applyAssembledCommentMedia(commentId: msgId, voicePath: p);
      }
    } else if (isFile) {
      final p = await img.assembleAndSaveFile(msgId);
      if (p != null) {
        img.markCompleted(msgId);
        final sz = kIsWeb ? _dataUriSize(p) : await File(p).length();
        await ChannelService.instance.applyAssembledCommentMedia(
            commentId: msgId, filePath: p, fileName: fileName, fileSize: sz);
      }
    } else if (isVideo) {
      final p = await img.assembleAndSaveVideo(msgId);
      if (p != null) {
        img.markCompleted(msgId);
        await ChannelService.instance
            .applyAssembledCommentMedia(commentId: msgId, videoPath: p);
      }
    } else {
      final p = await img.assembleAndSave(msgId);
      if (p != null) {
        img.markCompleted(msgId);
        await ChannelService.instance
            .applyAssembledCommentMedia(commentId: msgId, imagePath: p);
      }
    }
  }

  Future<void> _deliverToGroup(
      String msgId, bool isVideo, bool isSquare) async {
    final img = ImageService.instance;
    if (isVideo) {
      final p = await img.assembleAndSaveVideo(msgId, isSquare: isSquare);
      if (p != null) {
        img.markCompleted(msgId);
        await GroupService.instance.applyAssembledVideo(msgId, p);
      }
    } else {
      final p = await img.assembleAndSave(msgId);
      if (p != null) {
        img.markCompleted(msgId);
        await GroupService.instance.applyAssembledImage(msgId, p);
      }
    }
  }

  Future<bool> _tryStory(String msgId) async {
    final img = ImageService.instance;
    final story = StoryService.instance.findStory(msgId);
    if (story != null) {
      final p = await img.assembleAndSave(msgId);
      if (p != null) {
        img.markCompleted(msgId);
        story.imagePath = p;
        StoryService.instance.notifyUpdate();
      }
      return true;
    }
    // Cache for later
    final p = await img.assembleAndSave(msgId);
    if (p != null) StoryService.instance.cachePendingImage(msgId, p);
    return false;
  }

  Future<void> _deliverToDm({
    required String fromId,
    required String msgId,
    required bool isVoice,
    required bool isVideo,
    required bool isSquare,
    required bool isFile,
    required bool isSticker,
    required bool viewOnce,
    String? fileName,
    String? forwardFromId,
    String? forwardFromNick,
    String? forwardFromChannelId,
  }) async {
    final img = ImageService.instance;
    final myKey = CryptoService.instance.publicKeyHex;
    String label;
    String? voicePath, videoPath, filePath, imagePath;
    int? fileSize;

    if (isVoice) {
      voicePath = await img.assembleAndSaveVoice(msgId);
      if (voicePath == null) return;
      label = '🎤 Голосовое';
    } else if (isFile) {
      filePath = await img.assembleAndSaveFile(msgId);
      if (filePath == null) return;
      fileSize =
          kIsWeb ? _dataUriSize(filePath) : await File(filePath).length();
      label = '📎 ${fileName ?? 'Файл'}';
    } else if (isVideo) {
      videoPath = await img.assembleAndSaveVideo(msgId, isSquare: isSquare);
      if (videoPath == null) return;
      label = isSquare ? '⬛ Видео' : '📹 Видео';
    } else {
      imagePath = await img.assembleAndSave(msgId);
      if (imagePath == null) return;
      label = '';
    }

    img.markCompleted(msgId);

    final msg = ChatMessage(
      id: msgId,
      peerId: fromId,
      text: label,
      isOutgoing: false,
      timestamp: DateTime.now(),
      status: MessageStatus.delivered,
      voicePath: voicePath,
      videoPath: videoPath,
      filePath: filePath,
      fileName: fileName,
      fileSize: fileSize,
      imagePath: imagePath,
      isSticker: isSticker,
      viewOnce: viewOnce,
      forwardFromId: forwardFromId,
      forwardFromNick: forwardFromNick,
      forwardFromChannelId: forwardFromChannelId,
    );
    await ChatStorageService.instance.saveMessage(msg);
    _incomingMessageController.add(msg);

    if (myKey.isNotEmpty) {
      unawaited(GossipRouter.instance
          .sendAck(messageId: msgId, senderId: myKey, recipientId: fromId));
    }
    onNotify?.call(fromId, label.isNotEmpty ? label : '📷 Фото');
  }
}

int? _dataUriSize(String value) {
  final idx = value.indexOf(',');
  if (!value.startsWith('data:') || idx < 0) return null;
  try {
    return base64Decode(value.substring(idx + 1)).length;
  } catch (_) {
    return null;
  }
}
