import 'package:flutter/material.dart';

/// A selectable colour scheme. [seed] drives the Material ColorScheme; [gradient]
/// is used by the optional animated-gradient background.
class AppPalette {
  final String name;
  final Color seed;
  final List<Color> gradient;
  const AppPalette(this.name, this.seed, this.gradient);
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
];

AppPalette paletteFor(int index) =>
    (index >= 0 && index < kAppPalettes.length) ? kAppPalettes[index] : kAppPalettes[0];
