import 'package:video_player/video_player.dart';

VideoPlayerController videoControllerForPath(String path) =>
    VideoPlayerController.networkUrl(Uri.parse(path));

bool localFileExistsForPath(String path) => false;

Future<void> copyLocalFileToDownloads(String path, String fileName) async {}
