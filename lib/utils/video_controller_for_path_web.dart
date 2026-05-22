import 'package:video_player/video_player.dart';

VideoPlayerController videoControllerForPath(String path) =>
    VideoPlayerController.networkUrl(Uri.parse(path));

bool localFileExistsForPath(String path) =>
    path.startsWith('blob:') ||
    path.startsWith('data:') ||
    path.startsWith('http://') ||
    path.startsWith('https://') ||
    path.startsWith('opfs://rlink/');

Future<void> copyLocalFileToDownloads(String path, String fileName) async {}
