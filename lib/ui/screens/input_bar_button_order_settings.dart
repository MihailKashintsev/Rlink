import 'package:flutter/material.dart';
import '../../l10n/app_l10n.dart';
import '../../services/app_settings.dart';

/// Экран настроек порядка кнопок панели ввода с drag-and-drop
class InputBarButtonOrderSettings extends StatefulWidget {
  const InputBarButtonOrderSettings({super.key});

  @override
  State<InputBarButtonOrderSettings> createState() =>
      _InputBarButtonOrderSettingsState();
}

class _InputBarButtonOrderSettingsState
    extends State<InputBarButtonOrderSettings> {
  late List<Map<String, dynamic>> _buttonConfig;

  @override
  void initState() {
    super.initState();
    _buttonConfig = List.from(AppSettings.instance.inputBarButtonConfig);
  }

  Future<void> _saveOrder() async {
    await AppSettings.instance.setInputBarButtonConfig(_buttonConfig);
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Порядок кнопок сохранён')),
      );
    }
  }

  void _resetToDefault() {
    setState(() {
      _buttonConfig = const [
        {'id': 'emoji_stickers', 'side': 'left'},
        {'id': 'media_menu', 'side': 'left'},
      ];
    });
  }

  void _moveItem(int fromIndex, int toIndex) {
    if (fromIndex == toIndex) return;
    setState(() {
      final item = _buttonConfig.removeAt(fromIndex);
      _buttonConfig.insert(toIndex, item);
    });
    _autoSave();
  }

  void _toggleSide(int index) {
    setState(() {
      _buttonConfig[index] = {
        'id': _buttonConfig[index]['id'],
        'side': _buttonConfig[index]['side'] == 'left' ? 'right' : 'left',
      };
    });
    _autoSave();
  }

  void _autoSave() {
    AppSettings.instance.setInputBarButtonConfig(_buttonConfig);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Порядок кнопок'),
        actions: [
          TextButton(
            onPressed: _resetToDefault,
            child: const Text('Сбросить'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Нажми на кнопку чтобы сменить сторону (←/→). Перетаскивай чтобы изменить порядок.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          // Interactive input bar preview
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                ..._buttonConfig
                    .asMap()
                    .entries
                    .where((e) => e.value['side'] == 'left')
                    .map((entry) => _DraggablePreviewButton(
                          buttonConfig: entry.value,
                          index: entry.key,
                          onToggleSide: () => _toggleSide(entry.key),
                          onMove: (fromIndex, toIndex) =>
                              _moveItem(fromIndex, toIndex),
                        )),
                const SizedBox(width: 2),
                Expanded(
                  child: Container(
                    height: 36,
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Center(
                      child: Text(
                        'Текст сообщения...',
                        style: TextStyle(
                          color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ..._buttonConfig
                    .asMap()
                    .entries
                    .where((e) => e.value['side'] == 'right')
                    .map((entry) => _DraggablePreviewButton(
                          buttonConfig: entry.value,
                          index: entry.key,
                          onToggleSide: () => _toggleSide(entry.key),
                          onMove: (fromIndex, toIndex) =>
                              _moveItem(fromIndex, toIndex),
                        )),
                const SizedBox(width: 2),
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.send, color: Colors.white, size: 18),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: () async {
                await _saveOrder();
              },
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
              ),
              child: Text(AppL10n.t('common_done')),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draggable preview button shown in the input bar
class _DraggablePreviewButton extends StatelessWidget {
  final Map<String, dynamic> buttonConfig;
  final int index;
  final VoidCallback onToggleSide;
  final void Function(int fromIndex, int toIndex) onMove;

  const _DraggablePreviewButton({
    required this.buttonConfig,
    required this.index,
    required this.onToggleSide,
    required this.onMove,
  });

  IconData get _icon {
    final buttonId = buttonConfig['id'] as String;
    switch (buttonId) {
      case 'voice_video_square':
        return Icons.mic;
      case 'send_button':
        return Icons.send;
      case 'emoji_stickers':
        return Icons.emoji_emotions_outlined;
      case 'media_menu':
        return Icons.photo_library_outlined;
      default:
        return Icons.apps;
    }
  }

  String get _side => buttonConfig['side'] as String;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LongPressDraggable<Map<String, dynamic>>(
      data: buttonConfig,
      onDragStarted: () {},
      onDragCompleted: () {},
      feedback: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: cs.primary,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(_icon, color: Colors.white, size: 20),
      ),
      child: DragTarget<Map<String, dynamic>>(
        onAccept: (data) {
          final fromIndex = index;
          final toIndex = index;
          if (fromIndex != toIndex) {
            onMove(fromIndex, toIndex);
          }
        },
        builder: (context, candidateData, rejectedData) {
          return GestureDetector(
            onTap: onToggleSide,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: _side == 'left'
                    ? cs.primaryContainer
                    : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _icon,
                    size: 18,
                    color: _side == 'left'
                        ? cs.onPrimaryContainer
                        : cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _side == 'left' ? '←' : '→',
                    style: TextStyle(
                      color: _side == 'left'
                          ? cs.onPrimaryContainer
                          : cs.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
