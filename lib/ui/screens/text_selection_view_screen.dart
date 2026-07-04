import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_l10n.dart';
import '../widgets/translate_action.dart';

/// Экран «Выделить текст»: показывает текст сообщения так, чтобы пользователь мог
/// надёжно выделить любую область и скопировать/перевести её — единым меню Rlink,
/// даже в web (read-only текст рисуется на canvas, поэтому нативное меню
/// Safari/iOS не перехватывает выделение).
class TextSelectionViewScreen extends StatelessWidget {
  final String text;
  const TextSelectionViewScreen({super.key, required this.text});

  void _toast(BuildContext context, String s) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Выделить текст'),
        actions: [
          IconButton(
            tooltip: 'Скопировать всё',
            icon: const Icon(Icons.copy_all),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              _toast(context, AppL10n.t('cm_msg_copied'));
            },
          ),
          IconButton(
            tooltip: 'Перевести всё',
            icon: const Icon(Icons.translate),
            onPressed: () => showTranslateResult(context, text),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          text,
          style: const TextStyle(fontSize: 17, height: 1.45),
          contextMenuBuilder: (ctx, editableState) {
            final items = List<ContextMenuButtonItem>.from(
                editableState.contextMenuButtonItems);
            final sel = editableState.textEditingValue.selection;
            if (sel.isValid && !sel.isCollapsed) {
              final selected =
                  sel.textInside(editableState.textEditingValue.text);
              items.add(ContextMenuButtonItem(
                label: 'Перевести',
                onPressed: () {
                  editableState.hideToolbar();
                  showTranslateResult(ctx, selected);
                },
              ));
            }
            return AdaptiveTextSelectionToolbar.buttonItems(
              anchors: editableState.contextMenuAnchors,
              buttonItems: items,
            );
          },
        ),
      ),
    );
  }
}
