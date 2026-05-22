import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

VideoPlayerController videoControllerForPath(String path) =>
    VideoPlayerController.file(File(path));

bool localFileExistsForPath(String path) =>
    path.isNotEmpty && File(path).existsSync();

Future<void> copyLocalFileToDownloads(String path, String fileName) async {
  final home = Platform.environment['HOME'] ?? '.';
  final downloads = Directory(p.join(home, 'Downloads'));
  if (!downloads.existsSync()) {
    downloads.createSync(recursive: true);
  }
  await File(path).copy(p.join(downloads.path, fileName));
}
