import 'dart:typed_data';

import 'dropbox_backup.dart';
import 'google_drive_channel_backup.dart';
import 'onedrive_backup.dart';

/// Dispatches group/channel backup calls to whichever cloud provider a
/// group/channel is configured for. Google Drive keeps its own richer,
/// longer-lived implementation (native sign-in, manual-token fallback);
/// OneDrive/Dropbox share the generic relay-linked one — same call shape
/// on all three, so callers never branch on provider themselves.
class BackupProviders {
  BackupProviders._();

  static const ids = ['google', 'onedrive', 'dropbox'];

  static String label(String id) => switch (id) {
        'onedrive' => 'OneDrive',
        'dropbox' => 'Dropbox',
        _ => 'Google Drive',
      };

  /// True if [id] has a usable linked account right now.
  static bool isLinked(String id) => switch (id) {
        'onedrive' => OneDriveBackup.instance.link.hasAccount,
        'dropbox' => DropboxBackup.instance.link.hasAccount,
        _ => GoogleDriveChannelBackup.hasRelayAccount ||
            GoogleDriveChannelBackup.hasValidManualCreds,
      };

  /// The account to publish/restore with for [id], when the caller has no
  /// more specific (e.g. per-channel) pairing of its own.
  static String? activePairing(String id) => switch (id) {
        'onedrive' => OneDriveBackup.instance.link.activePairing,
        'dropbox' => DropboxBackup.instance.link.activePairing,
        _ => GoogleDriveChannelBackup.activeRelayPairing,
      };

  static Future<String?> upload(
    String id, {
    required String fileName,
    required Uint8List ciphertext,
    String? existingFileId,
    String? accountPairing,
    String? channelId,
    // Only Google's API needs this; OneDrive/Dropbox infer content-type and
    // ignore it. Cosmetic (Drive's own file browser), never read back by us.
    String mimeType = 'application/octet-stream',
  }) {
    switch (id) {
      case 'onedrive':
        return OneDriveBackup.instance.uploadOrUpdateEncryptedFile(
          fileName: fileName,
          ciphertext: ciphertext,
          existingFileId: existingFileId,
          accountPairing: accountPairing,
          channelId: channelId,
        );
      case 'dropbox':
        return DropboxBackup.instance.uploadOrUpdateEncryptedFile(
          fileName: fileName,
          ciphertext: ciphertext,
          existingFileId: existingFileId,
          accountPairing: accountPairing,
          channelId: channelId,
        );
      default:
        return GoogleDriveChannelBackup.uploadOrUpdateEncryptedFile(
          fileName: fileName,
          ciphertext: ciphertext,
          existingFileId: existingFileId,
          accountPairing: accountPairing,
          channelId: channelId,
          mimeType: mimeType,
        );
    }
  }

  static Future<Uint8List?> download(String id, String fileId,
      {String? accountPairing}) {
    switch (id) {
      case 'onedrive':
        return OneDriveBackup.instance
            .downloadFileBytes(fileId, accountPairing: accountPairing);
      case 'dropbox':
        return DropboxBackup.instance
            .downloadFileBytes(fileId, accountPairing: accountPairing);
      default:
        return GoogleDriveChannelBackup.downloadFileBytes(fileId,
            accountPairing: accountPairing);
    }
  }

  static Future<void> delete(String id, String? fileId,
      {String? accountPairing}) {
    switch (id) {
      case 'onedrive':
        return OneDriveBackup.instance
            .deleteFileById(fileId, accountPairing: accountPairing);
      case 'dropbox':
        return DropboxBackup.instance
            .deleteFileById(fileId, accountPairing: accountPairing);
      default:
        return GoogleDriveChannelBackup.deleteFileById(fileId,
            accountPairing: accountPairing);
    }
  }

  static Future<String?> makePublic(String id, String fileId) {
    switch (id) {
      case 'onedrive':
        return OneDriveBackup.instance.makePublicAndGetDownloadUrl(fileId);
      case 'dropbox':
        return DropboxBackup.instance.makePublicAndGetDownloadUrl(fileId);
      default:
        return GoogleDriveChannelBackup.makePublicAndGetDownloadUrl(fileId);
    }
  }
}
