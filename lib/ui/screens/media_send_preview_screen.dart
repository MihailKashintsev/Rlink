import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Result returned by [MediaSendPreviewScreen]: the (possibly edited) image
/// bytes plus an optional caption typed by the user.
class MediaPreviewResult {
  final Uint8List bytes;
  final String caption;
  const MediaPreviewResult({required this.bytes, required this.caption});
}

/// Telegram-style "review before send" screen for a picked photo.
/// Lets the user rotate / crop the image and add a caption, then send.
/// Returns a [MediaPreviewResult] via `Navigator.pop`, or `null` if cancelled.
class MediaSendPreviewScreen extends StatefulWidget {
  final Uint8List imageBytes;
  final String? peerName;

  const MediaSendPreviewScreen({
    super.key,
    required this.imageBytes,
    this.peerName,
  });

  @override
  State<MediaSendPreviewScreen> createState() => _MediaSendPreviewScreenState();
}

class _MediaSendPreviewScreenState extends State<MediaSendPreviewScreen> {
  late Uint8List _bytes;
  final _captionCtrl = TextEditingController();
  final _cropController = CropController();
  bool _cropMode = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _bytes = widget.imageBytes;
  }

  @override
  void dispose() {
    _captionCtrl.dispose();
    super.dispose();
  }

  Future<void> _rotate() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final decoded = img.decodeImage(_bytes);
      if (decoded != null) {
        final rotated = img.copyRotate(decoded, angle: 90);
        final out = Uint8List.fromList(img.encodeJpg(rotated, quality: 90));
        if (mounted) setState(() => _bytes = out);
      }
    } catch (_) {
      // Non-decodable image — leave as-is.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _send() {
    Navigator.pop(
      context,
      MediaPreviewResult(bytes: _bytes, caption: _captionCtrl.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.peerName != null && widget.peerName!.isNotEmpty
              ? 'Отправить → ${widget.peerName}'
              : 'Отправить фото',
          style: const TextStyle(fontSize: 16),
        ),
        actions: _cropMode
            ? [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() => _busy = true);
                          _cropController.crop();
                        },
                  child: Text('Готово',
                      style: TextStyle(
                          color: cs.primary, fontWeight: FontWeight.w600)),
                ),
              ]
            : [
                IconButton(
                  tooltip: 'Повернуть',
                  onPressed: _busy ? null : _rotate,
                  icon: const Icon(Icons.rotate_right_rounded),
                ),
                IconButton(
                  tooltip: 'Обрезать',
                  onPressed: _busy
                      ? null
                      : () => setState(() => _cropMode = true),
                  icon: const Icon(Icons.crop_rounded),
                ),
              ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _cropMode
                ? Crop(
                    controller: _cropController,
                    image: _bytes,
                    onCropped: (result) {
                      setState(() {
                        _busy = false;
                        _cropMode = false;
                      });
                      switch (result) {
                        case CropSuccess(:final croppedImage):
                          setState(() => _bytes = croppedImage);
                        case CropFailure(:final cause):
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text('$cause'),
                                backgroundColor: Colors.red),
                          );
                      }
                    },
                    onStatusChanged: (s) {
                      if (s == CropStatus.cropping && !_busy) {
                        setState(() => _busy = true);
                      }
                    },
                    baseColor: Colors.black,
                    maskColor: Colors.black.withValues(alpha: 0.55),
                  )
                : InteractiveViewer(
                    minScale: 1,
                    maxScale: 4,
                    child: Center(
                      child: Image.memory(_bytes, fit: BoxFit.contain),
                    ),
                  ),
          ),
          if (!_cropMode)
            SafeArea(
              top: false,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                color: Colors.black,
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: TextField(
                          controller: _captionCtrl,
                          minLines: 1,
                          maxLines: 4,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            hintText: 'Подпись...',
                            hintStyle: TextStyle(color: Colors.white54),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _busy ? null : _send,
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: cs.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.send_rounded,
                            color: cs.onPrimary, size: 22),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
