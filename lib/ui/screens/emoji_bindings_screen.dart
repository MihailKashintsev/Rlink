import 'package:flutter/material.dart';

import '../../models/emoji_binding.dart';
import '../../services/emoji_binding_service.dart';
import '../../services/emoji_pack_service.dart';
import '../widgets/channel_feed_image.dart' show storedImage;

/// Views and removes emoji→sticker/custom-emoji bindings. New bindings are
/// created from where the bound asset actually lives — the sticker hub's
/// "Привязать к эмодзи" snackbar action after exporting a sticker, and the
/// custom-emoji pack screen's long-press menu — not from here, so this
/// screen doesn't need to duplicate either picker.
class EmojiBindingsScreen extends StatefulWidget {
  const EmojiBindingsScreen({super.key});

  @override
  State<EmojiBindingsScreen> createState() => _EmojiBindingsScreenState();
}

class _EmojiBindingsScreenState extends State<EmojiBindingsScreen> {
  @override
  void initState() {
    super.initState();
    EmojiBindingService.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    EmojiBindingService.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bindings = EmojiBindingService.instance.allBindings;
    return Scaffold(
      appBar: AppBar(title: const Text('Привязки эмодзи')),
      body: bindings.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'Пока нет привязок. Их можно добавить после экспорта стикера '
                  'в мастерской стикеров, или долгим нажатием на кастомный '
                  'эмодзи в наборе.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
              itemCount: bindings.length,
              itemBuilder: (context, i) => _BindingTile(binding: bindings[i]),
            ),
    );
  }
}

class _BindingTile extends StatelessWidget {
  final EmojiBinding binding;

  const _BindingTile({required this.binding});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 10, top: 4),
            child: Text(binding.emoji, style: const TextStyle(fontSize: 28)),
          ),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final ref in binding.stickerRefs)
                  _RemovableThumb(
                    child: storedImage(ref, fit: BoxFit.contain, width: 44, height: 44),
                    onRemove: () => EmojiBindingService.instance
                        .removeStickerRef(binding.emoji, ref),
                  ),
                for (final sc in binding.customEmojiShortcodes)
                  _RemovableThumb(
                    child: () {
                      final img = EmojiPackService.instance.emojiImageProvider(sc);
                      return img == null
                          ? const Icon(Icons.emoji_emotions_outlined)
                          : Image(image: img, width: 32, height: 32, fit: BoxFit.contain);
                    }(),
                    onRemove: () => EmojiBindingService.instance
                        .removeCustomEmojiShortcode(binding.emoji, sc),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RemovableThumb extends StatelessWidget {
  final Widget child;
  final VoidCallback onRemove;

  const _RemovableThumb({required this.child, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        SizedBox(width: 44, height: 44, child: Center(child: child)),
        Positioned(
          right: -6,
          top: -6,
          child: InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
              child: const Icon(Icons.close, size: 12, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}
