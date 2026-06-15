import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/models/chat_message.dart';
import 'package:rlink/ui/widgets/missing_local_media.dart';

void main() {
  test(
    'opfs media refs are treated as available on web',
    () {
      final msg = ChatMessage(
        id: 'm1',
        peerId: 'peer',
        text: '📷 Фото',
        imagePath: 'opfs://rlink/chat/m1/photo.jpg',
        isOutgoing: true,
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      );

      expect(dmMessageMissingLocalMedia(msg), isFalse);
    },
    skip: !kIsWeb ? 'Web-only media ref behavior' : null,
  );
}
