import 'package:flutter/material.dart';

import '../../services/app_settings.dart';
import '../app_palettes.dart';

/// Дизайн-токены «нового дизайна» Rlink (эстетика интро-анимации: градиент
/// акцента + мягкое свечение + крупные скругления). Полная инструкция —
/// DESIGN.md в корне репозитория.
///
/// Всё гейтится [on] — при выключенном тумблере экраны обязаны показывать
/// старый вид (старые ветки кода не удаляем).
class RlinkDesign {
  RlinkDesign._();

  /// Единственный гейт нового дизайна.
  static bool get on => AppSettings.instance.newDesign;

  /// Градиент акцента текущей палитры (как бейджи в интро).
  static LinearGradient accentGradient(ColorScheme cs) {
    final g = paletteFor(AppSettings.instance.appPalette).gradient;
    final a = g.isNotEmpty ? g[0] : cs.primary;
    final b = g.length > 1 ? g[1] : cs.primary;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [a, Color.lerp(a, b, 0.75) ?? b],
    );
  }

  static Color accent(ColorScheme cs) =>
      paletteFor(AppSettings.instance.appPalette).accentColor;

  /// Контрастный цвет текста поверх градиента акцента.
  static Color onAccent(ColorScheme cs) =>
      accent(cs).computeLuminance() > 0.55
          ? const Color(0xFF0A0A0A)
          : Colors.white;

  /// Исходящий пузырь: градиент акцента + мягкое свечение.
  static BoxDecoration bubbleOut(ColorScheme cs, BorderRadius radius) =>
      BoxDecoration(
        gradient: accentGradient(cs),
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: accent(cs).withValues(alpha: 0.30),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      );

  /// Входящий пузырь: поверхность + волосяная обводка акцента.
  static BoxDecoration bubbleIn(ColorScheme cs, BorderRadius radius) =>
      BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: radius,
        border: Border.all(
          color: accent(cs).withValues(alpha: 0.10),
          width: 1,
        ),
      );

  /// «Плавающая» карточка (пост канала, плитка): поверхность + hairline +
  /// свечение акцента — как карточки в интро.
  static BoxDecoration floatCard(ColorScheme cs, {double radius = 22}) =>
      BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: accent(cs).withValues(alpha: 0.18),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: accent(cs).withValues(alpha: 0.10),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      );

  /// Аватар в градиентном кольце (как сторис/бейджи интро).
  static Widget gradientRing({
    required Widget child,
    required ColorScheme cs,
    double width = 2,
    double padding = 2,
  }) =>
      Container(
        padding: EdgeInsets.all(width),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: accentGradient(cs),
        ),
        child: Container(
          padding: EdgeInsets.all(padding),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: cs.surface,
          ),
          child: child,
        ),
      );
}
