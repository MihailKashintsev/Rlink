import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/models/chat_message.dart';
import 'package:rlink/ui/screens/chat_screen.dart';

/// isGroupablePhotoPair infers a multi-photo batch send purely from fields
/// already saved on each ChatMessage (no group id, no protocol change) — it
/// chains matching bubbles into one visual block. Every branch gets a case:
/// wrong sender, captioned, video, sticker, reply, and the time cutoff.
void main() {
  ChatMessage photo({
    String peerId = 'peer',
    bool isOutgoing = true,
    String text = '',
    String? imagePath = '/tmp/a.jpg',
    String? videoPath,
    bool isSticker = false,
    String? replyToMessageId,
    required DateTime timestamp,
  }) =>
      ChatMessage(
        id: 'id-${timestamp.microsecondsSinceEpoch}',
        peerId: peerId,
        text: text,
        imagePath: imagePath,
        videoPath: videoPath,
        isSticker: isSticker,
        replyToMessageId: replyToMessageId,
        isOutgoing: isOutgoing,
        timestamp: timestamp,
      );

  final t0 = DateTime(2026, 1, 1, 12, 0, 0);

  test('two bare photos from the same sender, seconds apart: groups', () {
    final a = photo(timestamp: t0);
    final b = photo(timestamp: t0.add(const Duration(seconds: 3)));
    expect(isGroupablePhotoPair(a, b), isTrue);
    expect(isGroupablePhotoPair(b, a), isTrue, reason: 'symmetric');
  });

  test('different senders (in/out): does not group', () {
    final a = photo(timestamp: t0, isOutgoing: true);
    final b = photo(timestamp: t0.add(const Duration(seconds: 1)), isOutgoing: false);
    expect(isGroupablePhotoPair(a, b), isFalse);
  });

  test('a caption on either photo: does not group', () {
    final a = photo(timestamp: t0, text: 'привет');
    final b = photo(timestamp: t0.add(const Duration(seconds: 1)));
    expect(isGroupablePhotoPair(a, b), isFalse);
    expect(isGroupablePhotoPair(b, a), isFalse);
  });

  test('a video message: does not group', () {
    final a = photo(timestamp: t0, imagePath: null, videoPath: '/tmp/a.mp4');
    final b = photo(timestamp: t0.add(const Duration(seconds: 1)));
    expect(isGroupablePhotoPair(a, b), isFalse);
  });

  test('a sticker: does not group', () {
    final a = photo(timestamp: t0, isSticker: true);
    final b = photo(timestamp: t0.add(const Duration(seconds: 1)));
    expect(isGroupablePhotoPair(a, b), isFalse);
  });

  test('an stk_-named image path (legacy sticker marker): does not group', () {
    final a = photo(timestamp: t0, imagePath: '/tmp/stk_default_1.png');
    final b = photo(timestamp: t0.add(const Duration(seconds: 1)));
    expect(isGroupablePhotoPair(a, b), isFalse);
  });

  test('a reply on either photo: does not group', () {
    final a = photo(timestamp: t0, replyToMessageId: 'other-msg');
    final b = photo(timestamp: t0.add(const Duration(seconds: 1)));
    expect(isGroupablePhotoPair(a, b), isFalse);
  });

  test('within the 20s cutoff: groups; past it: does not', () {
    final a = photo(timestamp: t0);
    final justInside = photo(timestamp: t0.add(const Duration(seconds: 20)));
    final justOutside = photo(timestamp: t0.add(const Duration(seconds: 21)));
    expect(isGroupablePhotoPair(a, justInside), isTrue);
    expect(isGroupablePhotoPair(a, justOutside), isFalse);
  });

  test('one has no image at all: does not group', () {
    final a = photo(timestamp: t0, imagePath: null);
    final b = photo(timestamp: t0.add(const Duration(seconds: 1)));
    expect(isGroupablePhotoPair(a, b), isFalse);
  });
}
