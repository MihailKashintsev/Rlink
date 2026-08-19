import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:lottie/lottie.dart';

import '../../models/tgs_sticker.dart';

/// Plays a Telegram `.tgs` sticker via the `lottie` package. Deliberately
/// thin: `.tgs` bytes are gzip-compressed Lottie/Bodymovin JSON, and the
/// package already renders that spec correctly — see `tgs_sticker.dart` for
/// why we don't hand-roll a Lottie parser ourselves.
class TgsStickerView extends StatelessWidget {
  final Uint8List tgsBytes;
  final double? width;
  final double? height;

  const TgsStickerView({super.key, required this.tgsBytes, this.width, this.height});

  @override
  Widget build(BuildContext context) {
    final lottieJson = gunzipTgsToLottieJson(tgsBytes);
    if (lottieJson == null) return SizedBox(width: width, height: height);
    return Lottie.memory(
      lottieJson,
      width: width,
      height: height,
      repeat: true,
      errorBuilder: (_, __, ___) => SizedBox(width: width, height: height),
    );
  }
}
