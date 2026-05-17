import 'package:flutter/material.dart';

/// A customizable keyboard accessory bar that appears above the keyboard.
/// Buttons can be reordered and toggled in Settings.
class KeyboardAccessoryBar extends StatelessWidget {
  final VoidCallback? onEmoji;
  final VoidCallback? onSticker;
  final VoidCallback? onGallery;
  final VoidCallback? onCamera;
  final VoidCallback? onFile;
  final VoidCallback? onLocation;
  final VoidCallback? onContact;
  final VoidCallback? onPoll;
  final VoidCallback? onVoiceMessage;
  final List<KeyboardAccessoryButton> buttons;

  const KeyboardAccessoryBar({
    super.key,
    this.onEmoji,
    this.onSticker,
    this.onGallery,
    this.onCamera,
    this.onFile,
    this.onLocation,
    this.onContact,
    this.onPoll,
    this.onVoiceMessage,
    this.buttons = KeyboardAccessoryButton.defaults,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final activeButtons = _resolveButtons();

    if (activeButtons.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          top: BorderSide(color: cs.outline.withValues(alpha: 0.15)),
        ),
      ),
      child: Row(
        children: activeButtons.map((btn) {
          final cb = _callbackFor(btn);
          return Expanded(
            child: InkWell(
              onTap: cb,
              borderRadius: BorderRadius.circular(8),
              child: Center(
                child: Icon(
                  _iconFor(btn),
                  size: 22,
                  color: cb != null
                      ? cs.onSurfaceVariant
                      : cs.onSurface.withValues(alpha: 0.25),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  List<KeyboardAccessoryButton> _resolveButtons() {
    if (buttons.isEmpty) return KeyboardAccessoryButton.defaults;
    return buttons;
  }

  IconData _iconFor(KeyboardAccessoryButton btn) {
    switch (btn) {
      case KeyboardAccessoryButton.emoji:
        return Icons.mood_rounded;
      case KeyboardAccessoryButton.sticker:
        return Icons.emoji_emotions_outlined;
      case KeyboardAccessoryButton.gallery:
        return Icons.photo_library_outlined;
      case KeyboardAccessoryButton.camera:
        return Icons.camera_alt_outlined;
      case KeyboardAccessoryButton.file:
        return Icons.attach_file_rounded;
      case KeyboardAccessoryButton.location:
        return Icons.location_on_outlined;
      case KeyboardAccessoryButton.contact:
        return Icons.person_add_outlined;
      case KeyboardAccessoryButton.poll:
        return Icons.poll_outlined;
      case KeyboardAccessoryButton.voiceMessage:
        return Icons.keyboard_voice_outlined;
    }
  }

  VoidCallback? _callbackFor(KeyboardAccessoryButton btn) {
    switch (btn) {
      case KeyboardAccessoryButton.emoji:
        return onEmoji;
      case KeyboardAccessoryButton.sticker:
        return onSticker;
      case KeyboardAccessoryButton.gallery:
        return onGallery;
      case KeyboardAccessoryButton.camera:
        return onCamera;
      case KeyboardAccessoryButton.file:
        return onFile;
      case KeyboardAccessoryButton.location:
        return onLocation;
      case KeyboardAccessoryButton.contact:
        return onContact;
      case KeyboardAccessoryButton.poll:
        return onPoll;
      case KeyboardAccessoryButton.voiceMessage:
        return onVoiceMessage;
    }
  }
}

enum KeyboardAccessoryButton {
  emoji,
  sticker,
  gallery,
  camera,
  file,
  location,
  contact,
  poll,
  voiceMessage;

  static const defaults = [
    KeyboardAccessoryButton.emoji,
    KeyboardAccessoryButton.gallery,
    KeyboardAccessoryButton.camera,
    KeyboardAccessoryButton.file,
    KeyboardAccessoryButton.voiceMessage,
  ];

  String displayName() {
    switch (this) {
      case KeyboardAccessoryButton.emoji:
        return 'Эмодзи';
      case KeyboardAccessoryButton.sticker:
        return 'Стикеры';
      case KeyboardAccessoryButton.gallery:
        return 'Галерея';
      case KeyboardAccessoryButton.camera:
        return 'Камера';
      case KeyboardAccessoryButton.file:
        return 'Файл';
      case KeyboardAccessoryButton.location:
        return 'Локация';
      case KeyboardAccessoryButton.contact:
        return 'Контакт';
      case KeyboardAccessoryButton.poll:
        return 'Опрос';
      case KeyboardAccessoryButton.voiceMessage:
        return 'Голосовое';
    }
  }
}
