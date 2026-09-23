import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show Theme;

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

bool get _rlinkSkipChatEnterFade {
  if (kIsWeb) return false;
  try {
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  } catch (_) {
    return false;
  }
}

/// Открытие личного чата: Cupertino + плавное проявление от прозрачности.
Route<T> rlinkChatRoute<T>(Widget page) {
  if (_rlinkSkipChatEnterFade) {
    return CupertinoPageRoute<T>(builder: (_) => page);
  }
  return CupertinoPageRoute<T>(
    builder: (context) => _RlinkChatEnterFade(child: page),
  );
}

class _RlinkChatEnterFade extends StatelessWidget {
  final Widget child;

  const _RlinkChatEnterFade({required this.child});

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final animation = route?.animation;
    if (animation == null) return child;

    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        // easeIn on the closing half delays the fade right when it starts —
        // exits read as responsive with ease-out too (see improve-animations
        // audit, 2026-09-23).
        reverseCurve: Curves.easeOutCubic,
      ),
      child: child,
    );
  }
}
