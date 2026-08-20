import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/services/call_history_service.dart';

void main() {
  group('CallHistoryEntry outcome round-trips', () {
    for (final outcome in ['missed', 'declined', null]) {
      test('outcome=$outcome survives toJson/fromJson', () {
        final entry = CallHistoryEntry(
          id: 'x_1',
          peerId: 'a' * 64,
          peerDisplayName: 'Тест',
          endedAtMs: 12345,
          durationMs: 0,
          incoming: true,
          video: false,
          outcome: outcome,
        );
        final round = CallHistoryEntry.fromJson(entry.toJson());
        expect(round.outcome, outcome);
        expect(round.incoming, true);
        expect(round.durationMs, 0);
      });
    }

    test('a connected call (positive duration) has no outcome by default',
        () {
      final entry = CallHistoryEntry(
        id: 'x_2',
        peerId: 'b' * 64,
        peerDisplayName: 'Тест',
        endedAtMs: 1,
        durationMs: 42000,
        incoming: false,
        video: true,
      );
      expect(entry.outcome, isNull);
      final round = CallHistoryEntry.fromJson(entry.toJson());
      expect(round.outcome, isNull);
      expect(round.durationMs, 42000);
    });

    test('legacy JSON with no outcome key decodes with outcome null', () {
      final legacy = {
        'id': 'x_3',
        'peerId': 'c' * 64,
        'peerDisplayName': 'Старый',
        'endedAtMs': 1,
        'durationMs': 0,
        'incoming': true,
        'video': false,
      };
      final entry = CallHistoryEntry.fromJson(legacy);
      expect(entry.outcome, isNull);
    });
  });
}
