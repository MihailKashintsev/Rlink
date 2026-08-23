import 'package:flutter/material.dart';

import '../../services/emoji_binding_service.dart';

/// Prompts for an emoji (typed via the OS's own emoji keyboard/paste — no
/// custom picker needed) and binds it to a sticker (send-after) or a custom
/// emoji (replace-in-text). Exactly one of [stickerRef]/[customEmojiShortcode]
/// must be given.
Future<void> showBindToEmojiDialog(
  BuildContext context, {
  String? stickerRef,
  String? customEmojiShortcode,
}) async {
  assert((stickerRef == null) != (customEmojiShortcode == null),
      'pass exactly one of stickerRef or customEmojiShortcode');
  final controller = TextEditingController();
  final emoji = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Привязать к эмодзи'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            stickerRef != null
                ? 'Когда вы наберёте этот эмодзи в сообщении, будет предложено '
                    'отправить этот стикер следом.'
                : 'Когда вы наберёте этот эмодзи, будет предложено заменить его '
                    'на этот кастомный эмодзи.',
            style: TextStyle(fontSize: 13, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 28),
            decoration: const InputDecoration(hintText: '🙂'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () {
            final glyph = controller.text.trim();
            if (!EmojiBindingService.instance.isKnownEmoji(glyph)) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('Это не похоже на эмодзи')),
              );
              return;
            }
            Navigator.pop(ctx, glyph);
          },
          child: const Text('Привязать'),
        ),
      ],
    ),
  );
  if (emoji == null) return;
  if (stickerRef != null) {
    await EmojiBindingService.instance.addStickerBinding(emoji, stickerRef);
  } else {
    await EmojiBindingService.instance.addCustomEmojiBinding(emoji, customEmojiShortcode!);
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$emoji привязан')),
    );
  }
}
