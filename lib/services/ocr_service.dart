import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

class OcrBlock {
  final String text;
  // Bounding box in the coordinate space of the PNG bytes passed to recognize().
  final Rect boundingBox;
  OcrBlock({required this.text, required this.boundingBox});
}

class OcrService {
  // Runs on-device text recognition on [pngBytes].
  // Coordinate system of returned blocks matches the pixel dimensions of
  // the supplied PNG — caller is responsible for any viewport scaling.
  // Returns [] on web or unsupported platforms.
  static Future<List<OcrBlock>> recognizeFromBytes(Uint8List pngBytes) async {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) return [];

    final dir = await getTemporaryDirectory();
    final tmp = File('${dir.path}/rlink_ocr_tmp.png');
    await tmp.writeAsBytes(pngBytes);

    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result =
          await recognizer.processImage(InputImage.fromFilePath(tmp.path));
      return result.blocks
          .where((b) => b.text.trim().isNotEmpty)
          .map((b) => OcrBlock(text: b.text.trim(), boundingBox: b.boundingBox))
          .toList();
    } finally {
      await recognizer.close();
      try {
        await tmp.delete();
      } catch (_) {}
    }
  }
}
