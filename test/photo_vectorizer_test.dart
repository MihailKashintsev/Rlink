import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:rlink/services/photo_vectorizer.dart';
import 'package:xml/xml.dart';

void main() {
  /// A 60x60 white background with a 24x24 solid blue square — a stand-in
  /// for "a simple two-color subject photo".
  img.Image twoColorSample() {
    final image = img.Image(width: 60, height: 60, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(250, 250, 250, 255));
    for (var y = 18; y < 42; y++) {
      for (var x = 18; x < 42; x++) {
        image.setPixelRgba(x, y, 20, 60, 220, 255);
      }
    }
    return image;
  }

  test('produces well-formed SVG with at least one path', () {
    final svg = PhotoVectorizer.vectorize(
      img.encodePng(twoColorSample()),
      colorCount: 2,
      detail: 0.5,
    );
    final doc = XmlDocument.parse(svg); // throws if malformed
    final root = doc.rootElement;
    expect(root.name.local, 'svg');
    final paths = root.findElements('path').toList();
    expect(paths, isNotEmpty);
    for (final p in paths) {
      expect(p.getAttribute('d'), isNotNull);
      expect(p.getAttribute('fill'), matches(RegExp(r'^#[0-9a-f]{6}$')));
    }
  });

  test('a higher detail setting keeps at least as many points as a lower one', () {
    // Douglas-Peucker epsilon shrinks as detail rises, so simplification
    // removes fewer points — the low-detail path must never have MORE
    // points than the high-detail one for the same source image.
    final bytes = img.encodePng(twoColorSample());
    final lowDetail = PhotoVectorizer.vectorize(bytes, colorCount: 2, detail: 0.0);
    final highDetail = PhotoVectorizer.vectorize(bytes, colorCount: 2, detail: 1.0);

    int totalPointCount(String svg) {
      final doc = XmlDocument.parse(svg);
      var total = 0;
      for (final p in doc.rootElement.findElements('path')) {
        final d = p.getAttribute('d') ?? '';
        total += RegExp(r'[ML]').allMatches(d).length;
      }
      return total;
    }

    expect(totalPointCount(highDetail), greaterThanOrEqualTo(totalPointCount(lowDetail)));
  });

  test('more requested colors does not throw and still yields paths', () {
    final svg = PhotoVectorizer.vectorize(
      img.encodePng(twoColorSample()),
      colorCount: 8,
      detail: 0.5,
    );
    final doc = XmlDocument.parse(svg);
    expect(doc.rootElement.findElements('path'), isNotEmpty);
  });

  test('a tiny noise speck below the size floor is not traced as its own path', () {
    final image = twoColorSample();
    // A single stray pixel of a third color — should be filtered as noise,
    // not turned into its own (barely visible, jagged) path.
    image.setPixelRgba(2, 2, 10, 200, 10, 255);
    final svg = PhotoVectorizer.vectorize(
      img.encodePng(image),
      colorCount: 3,
      detail: 0.5,
    );
    final doc = XmlDocument.parse(svg);
    // Exactly the background + the blue square — the green speck must not
    // have survived as a third path.
    expect(doc.rootElement.findElements('path').length, lessThanOrEqualTo(2));
  });
}
