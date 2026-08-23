import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:rlink/services/background_removal.dart';

void main() {
  /// A 20x20 white background with a 6x6 solid red square in the middle —
  /// a stand-in for "a subject on a plain background".
  img.Image sample() {
    final image = img.Image(width: 20, height: 20, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(255, 255, 255, 255));
    for (var y = 7; y < 13; y++) {
      for (var x = 7; x < 13; x++) {
        image.setPixelRgba(x, y, 220, 30, 30, 255);
      }
    }
    return image;
  }

  test('clears the uniform background while leaving the subject opaque', () {
    final out = img.decodePng(BackgroundRemoval.remove(
      img.encodePng(sample()),
      tolerance: 0.1,
    ))!;

    expect(out.getPixel(0, 0).a, 0, reason: 'a corner pixel is background');
    expect(out.getPixel(19, 19).a, 0);
    expect(out.getPixel(10, 10).a, greaterThan(0),
        reason: 'the red square in the middle must survive');
    final subject = out.getPixel(10, 10);
    expect(subject.r, greaterThan(subject.g),
        reason: 'the surviving pixel should still be the red subject color');
  });

  test('a subject pixel that happens to touch the border is not erased', () {
    final image = sample();
    // A lone, clearly-subject-colored (red) pixel touching the border,
    // distinct from the white background around it — e.g. a photo where the
    // subject's edge just reaches the frame.
    image.setPixelRgba(5, 0, 220, 30, 30, 255);
    final out = img.decodePng(BackgroundRemoval.remove(
      img.encodePng(image),
      tolerance: 0.1,
    ))!;

    expect(out.getPixel(0, 0).a, 0, reason: 'a real white border pixel is erased');
    expect(out.getPixel(5, 0).a, greaterThan(0),
        reason: 'a red pixel must not be erased just for sitting on the border');
  });

  test('a fully uniform image with no distinct subject clears entirely', () {
    final image = img.Image(width: 10, height: 10, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(100, 150, 200, 255));
    final out = img.decodePng(BackgroundRemoval.remove(
      img.encodePng(image),
      tolerance: 0.1,
    ))!;
    for (var y = 0; y < 10; y++) {
      for (var x = 0; x < 10; x++) {
        expect(out.getPixel(x, y).a, 0);
      }
    }
  });
}
