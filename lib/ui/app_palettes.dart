import 'package:flutter/material.dart';

/// A named accent palette. [seed] drives the Material color scheme; [gradient]
/// is used by the optional animated-gradient background. The optional
/// [background]/[accent]/[dark] fields let a palette pin a full, contrasty look
/// (a specific background + accent + brightness) instead of deriving everything
/// from a single seed — used by the "contrast" palettes below.
class AppPalette {
  final String name;
  final Color seed;
  final List<Color> gradient;
  final Color? background;
  final Color? accent;
  final bool? dark;
  const AppPalette(
    this.name,
    this.seed,
    this.gradient, {
    this.background,
    this.accent,
    this.dark,
  });

  Color get accentColor => accent ?? seed;
}

const List<AppPalette> kAppPalettes = [
  AppPalette('Изумруд', Color(0xFF1DB954),
      [Color(0xFF1DB954), Color(0xFF0F9B8E), Color(0xFF2BC0A8)]),
  AppPalette('Океан', Color(0xFF2196F3),
      [Color(0xFF2196F3), Color(0xFF6A11CB), Color(0xFF1E88E5)]),
  AppPalette('Закат', Color(0xFFFF6F43),
      [Color(0xFFFF512F), Color(0xFFDD2476), Color(0xFFFF8A50)]),
  AppPalette('Аметист', Color(0xFF7C4DFF),
      [Color(0xFF7C4DFF), Color(0xFF448AFF), Color(0xFF9C6BFF)]),
  AppPalette('Роза', Color(0xFFEC407A),
      [Color(0xFFEC407A), Color(0xFFFF7043), Color(0xFFF06292)]),
  AppPalette('Лайм', Color(0xFF7CB342),
      [Color(0xFF7CB342), Color(0xFF26A69A), Color(0xFF9CCC65)]),
  AppPalette('Графит', Color(0xFF546E7A),
      [Color(0xFF37474F), Color(0xFF263238), Color(0xFF455A64)]),
  AppPalette('Золото', Color(0xFFD4A017),
      [Color(0xFFD4A017), Color(0xFFE65100), Color(0xFFFFB300)]),

  // ── Contrast palettes (background + accent pinned) ─────────────────────────
  AppPalette('Синий · Золото', Color(0xFFFFD700),
      [Color(0xFFFFD700), Color(0xFF1C2A54), Color(0xFF0A1128)],
      background: Color(0xFF0A1128), accent: Color(0xFFFFD700), dark: true),
  AppPalette('Токсик', Color(0xFFA8FF33),
      [Color(0xFFA8FF33), Color(0xFF2C6B34), Color(0xFF0A3622)],
      background: Color(0xFF0A3622), accent: Color(0xFFA8FF33), dark: true),
  AppPalette('Лимон · Графит', Color(0xFF242422),
      [Color(0xFF242422), Color(0xFF7A7860), Color(0xFFD8D262)],
      background: Color(0xFFD8D262), accent: Color(0xFF242422), dark: false),
  AppPalette('Какао · Небо', Color(0xFFCFE0F0),
      [Color(0xFFCFE0F0), Color(0xFF7E6A63), Color(0xFF3A2521)],
      background: Color(0xFF3A2521), accent: Color(0xFFCFE0F0), dark: true),
  AppPalette('Тиффани', Color(0xFF2DD4BF),
      [Color(0xFF2DD4BF), Color(0xFF0E7490), Color(0xFF030712)],
      background: Color(0xFF030712), accent: Color(0xFF2DD4BF), dark: true),
  AppPalette('Моно', Color(0xFFF8F9FA),
      [Color(0xFFF8F9FA), Color(0xFF6E6E6E), Color(0xFF1F1F1F)],
      background: Color(0xFF1F1F1F), accent: Color(0xFFF8F9FA), dark: true),
  AppPalette('Лаванда', Color(0xFF1B1330),
      [Color(0xFF1B1330), Color(0xFF5B4C7E), Color(0xFF7E6BA9)],
      background: Color(0xFF7E6BA9), accent: Color(0xFF1B1330), dark: false),
  AppPalette('Каштан', Color(0xFFE7E4E4),
      [Color(0xFFE7E4E4), Color(0xFF8A5A54), Color(0xFF441E1B)],
      background: Color(0xFF441E1B), accent: Color(0xFFE7E4E4), dark: true),
  AppPalette('Пергамент', Color(0xFF1B1B1B),
      [Color(0xFF1B1B1B), Color(0xFF8C8B6E), Color(0xFFF0EFD1)],
      background: Color(0xFFF0EFD1), accent: Color(0xFF1B1B1B), dark: false),
];

AppPalette paletteFor(int index) =>
    (index >= 0 && index < kAppPalettes.length)
        ? kAppPalettes[index]
        : kAppPalettes[0];
