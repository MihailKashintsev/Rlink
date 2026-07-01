import 'package:characters/characters.dart';

/// Bundled Google **Noto Animated Emoji** codes (Apache-2.0 / OFL, free for
/// commercial use). Assets: assets/animated_emoji/{code}.gif. Rendered inline
/// (at ~text size) by RichMessageText so any emoji you send is animated.
const Set<String> kNotoAnimated = {
  '1f31f', '1f339', '1f355', '1f382', '1f389', '1f38a', '1f431', '1f440', '1f44a', '1f44b', '1f44c', '1f44d', '1f44e', '1f44f', '1f450', '1f47b', '1f47d', '1f47e', '1f47f', '1f480', '1f494', '1f495', '1f496', '1f497', '1f499', '1f49a', '1f49b', '1f49c', '1f49e', '1f4a5', '1f4a9', '1f4aa', '1f4af', '1f525', '1f596', '1f5a4', '1f600', '1f601', '1f602', '1f603', '1f604', '1f605', '1f606', '1f607', '1f608', '1f609', '1f60a', '1f60b', '1f60c', '1f60d', '1f60e', '1f60f', '1f610', '1f611', '1f612', '1f613', '1f614', '1f615', '1f616', '1f617', '1f618', '1f619', '1f61a', '1f61b', '1f61c', '1f61d', '1f61e', '1f61f', '1f620', '1f621', '1f622', '1f623', '1f624', '1f625', '1f626', '1f627', '1f628', '1f629', '1f62a', '1f62b', '1f62c', '1f62d', '1f62e', '1f62f', '1f630', '1f631', '1f632', '1f633', '1f634', '1f635', '1f636', '1f637', '1f639', '1f63a', '1f641', '1f642', '1f643', '1f644', '1f64c', '1f64f', '1f90c', '1f90d', '1f90e', '1f90f', '1f910', '1f911', '1f912', '1f913', '1f914', '1f915', '1f916', '1f917', '1f918', '1f919', '1f91d', '1f91f', '1f920', '1f921', '1f922', '1f923', '1f924', '1f925', '1f927', '1f928', '1f929', '1f92a', '1f92b', '1f92c', '1f92d', '1f92e', '1f92f', '1f970', '1f971', '1f973', '1f974', '1f975', '1f976', '1f978', '1f97a', '1f981', '1f984', '1f98b', '1f9d0', '1f9e1', '26a1', '26bd', '2705', '270a', '270b', '270c_fe0f', '2728', '274c', '2764_fe0f', '2b50',
};

/// Maps a single emoji grapheme to its bundled Noto code (handling the VS16
/// `fe0f` variation selector), or null if we don't have an animation for it.
String? notoAnimatedCodeFor(String grapheme) {
  final runes = grapheme.runes.toList();
  if (runes.isEmpty) return null;
  final exact = runes.map((r) => r.toRadixString(16)).join('_');
  if (kNotoAnimated.contains(exact)) return exact;
  final noVs =
      runes.where((r) => r != 0xFE0F).map((r) => r.toRadixString(16)).join('_');
  if (noVs.isNotEmpty && kNotoAnimated.contains(noVs)) return noVs;
  if (runes.length == 1) {
    final withVs = '${runes.first.toRadixString(16)}_fe0f';
    if (kNotoAnimated.contains(withVs)) return withVs;
  }
  return null;
}

/// Walks [s] and returns (start, end, code) for each emoji grapheme that has a
/// bundled Noto animation, using UTF-16 code-unit offsets (for span slicing).
Iterable<(int, int, String)> notoEmojiRanges(String s) sync* {
  var offset = 0;
  for (final g in s.characters) {
    final len = g.length;
    final code = notoAnimatedCodeFor(g);
    if (code != null) yield (offset, offset + len, code);
    offset += len;
  }
}
