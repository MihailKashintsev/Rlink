import 'package:video_player/video_player.dart';

import 'video_controller_for_path_stub.dart'
    if (dart.library.io) 'video_controller_for_path_io.dart'
    if (dart.library.html) 'video_controller_for_path_web.dart' as impl;

VideoPlayerController videoControllerForPath(String path) =>
    impl.videoControllerForPath(path);

bool localFileExistsForPath(String path) => impl.localFileExistsForPath(path);

Future<void> copyLocalFileToDownloads(String path, String fileName) =>
    impl.copyLocalFileToDownloads(path, fileName);
