import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show ColoredBox, Theme;

/// Переходы в стиле iOS: свайп от левого края для возврата (на iOS и в типичной конфигурации).
Route<T> rlinkPushRoute<T>(Widget page) {
  return CupertinoPageRoute<T>(
    builder: (_) => page,
  );
}

/// Как [rlinkPushRoute], но подкладывает НЕПРОЗРАЧНЫЙ фон под страницу.
///
/// В новом дизайне scaffoldBackgroundColor = transparent, чтобы на главных
/// экранах просвечивала общая AuroraBackground. Но для вложенных страниц
/// (настройки и их вкладки) это давало «наслоение»: во время slide-перехода
/// прозрачная страница не перекрывала предыдущую, и тексты накладывались друг
/// на друга. Этот роут гарантирует сплошной фон под любой открываемой вкладкой.
Route<T> rlinkOpaquePushRoute<T>(Widget page) {
  return CupertinoPageRoute<T>(
    builder: (context) => ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: page,
    ),
  );
}

/// Открытие личного чата: Cupertino-сдвиг. Чат наезжает справа налево, а
/// экран под ним (главный / откуда открыли) чуть сдвигается влево — и обратно
/// при выходе. Это делает сам Cupertino-роут (delegatedTransition для нижнего
/// роута), поэтому страница чата должна быть НЕПРОЗРАЧНОЙ: раньше поверх
/// сдвига накладывалось затухание, и во время перехода сквозь чат просвечивал
/// уезжающий экран — отсюда «баг» при открытии.
Route<T> rlinkChatRoute<T>(Widget page) {
  return CupertinoPageRoute<T>(
    builder: (context) => ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: page,
    ),
  );
}
