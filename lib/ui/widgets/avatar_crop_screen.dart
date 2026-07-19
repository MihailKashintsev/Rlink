import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_l10n.dart';

/// Обрезка аватара с предпросмотром: круглая область (как аватар в профиле),
/// результат — квадрат, поэтому картинка НИКОГДА не растягивается, даже если
/// исходное фото не квадратное. Возвращает обрезанные байты (или null).
class AvatarCropScreen extends StatefulWidget {
  final Uint8List imageBytes;
  const AvatarCropScreen({super.key, required this.imageBytes});

  @override
  State<AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends State<AvatarCropScreen> {
  final _controller = CropController();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        title: const Text('Обрезка аватара'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: cs.primary,
                foregroundColor: cs.onPrimary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                padding: const EdgeInsets.symmetric(horizontal: 18),
              ),
              onPressed: _busy
                  ? null
                  : () {
                      setState(() => _busy = true);
                      _controller.crop();
                    },
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(AppL10n.t('common_done')),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Crop(
              controller: _controller,
              image: widget.imageBytes,
              withCircleUi: true, // круглая область = как выглядит аватар (1:1)
              baseColor: const Color(0xFF0B0B0F),
              maskColor: Colors.black.withValues(alpha: 0.62),
              onCropped: (result) {
                if (!mounted) return;
                setState(() => _busy = false);
                switch (result) {
                  case CropSuccess(:final croppedImage):
                    Navigator.pop(context, croppedImage);
                  case CropFailure():
                    Navigator.pop(context, null);
                }
              },
              onStatusChanged: (s) {
                if (s == CropStatus.cropping && mounted) {
                  setState(() => _busy = true);
                }
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
            child: Text(
              'Двигайте и масштабируйте фото — так аватар и будет выглядеть.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.66),
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
