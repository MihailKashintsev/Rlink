import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/utils/message_preview_formatter.dart';

void main() {
  group('spoiler is never revealed in a preview', () {
    test('a message that is entirely a spoiler is masked, not shown raw', () {
      final out = formatMessagePreview('||секретный план||');
      expect(out, isNot(contains('секретный')));
      expect(out, isNot(contains('||')));
      expect(out, '🙈');
    });

    test('a spoiler embedded in surrounding text hides only its own content', () {
      final out = formatMessagePreview('приходи ||в 19:00 на площадь|| завтра');
      expect(out, isNot(contains('19:00')));
      expect(out, isNot(contains('||')));
      expect(out, contains('приходи'));
      expect(out, contains('завтра'));
    });

    test('multiple spoilers in one message are each masked independently', () {
      final out = formatMessagePreview('||раз|| и ||два||');
      expect(out, isNot(contains('раз')));
      expect(out, isNot(contains('два')));
      expect(out, isNot(contains('||')));
    });
  });

  group('other formatting markers collapse to readable text', () {
    test('bold', () => expect(formatMessagePreview('**важно**'), 'важно'));
    test('underline', () => expect(formatMessagePreview('__подчёркнуто__'), 'подчёркнуто'));
    test('strikethrough', () => expect(formatMessagePreview('~~зачёркнуто~~'), 'зачёркнуто'));
    test('mono', () => expect(formatMessagePreview('`код`'), 'код'));
    test('italic', () => expect(formatMessagePreview('_курсив_'), 'курсив'));
    test('markdown link shows its label, not the raw URL',
        () => expect(formatMessagePreview('[сайт](https://example.com)'), 'сайт'));
  });

  test('plain text with no markers passes through unchanged', () {
    expect(formatMessagePreview('обычное сообщение'), 'обычное сообщение');
  });

  test('stripPreviewFormatting is exposed directly and matches the same behavior', () {
    expect(stripPreviewFormatting('||x||'), '🙈');
    expect(stripPreviewFormatting('**b**'), 'b');
  });
}
