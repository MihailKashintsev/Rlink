import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/services/call_service.dart';
import 'package:rlink/ui/widgets/incoming_call_fullscreen_banner.dart';

void main() {
  testWidgets('renders name, ring, and both action buttons', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: IncomingCallFullscreenBanner(
        session: const CallSessionInfo(
          callId: 'c1',
          peerId: 'peer1',
          incoming: true,
          videoEnabled: false,
          audioEnabled: true,
        ),
        peerName: 'Тестовый Контакт',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Тестовый Контакт'), findsOneWidget);
    expect(find.text('Входящий аудиозвонок'), findsOneWidget);
    expect(find.text('Принять'), findsOneWidget);
    expect(find.text('Отклонить'), findsOneWidget);
    expect(find.byIcon(Icons.call_rounded), findsWidgets);
    expect(find.byIcon(Icons.call_end_rounded), findsOneWidget);
  });

  testWidgets('video call shows video label and camera icon', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: IncomingCallFullscreenBanner(
        session: const CallSessionInfo(
          callId: 'c2',
          peerId: 'peer2',
          incoming: true,
          videoEnabled: true,
          audioEnabled: true,
        ),
        peerName: 'Видео Контакт',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Входящий видеозвонок'), findsOneWidget);
    expect(find.byIcon(Icons.videocam_rounded), findsWidgets);
  });

  testWidgets('no overflow on a narrow phone screen (small budget device)',
      (tester) async {
    final originalSize = tester.view.physicalSize;
    final originalRatio = tester.view.devicePixelRatio;
    addTearDown(() {
      tester.view.physicalSize = originalSize;
      tester.view.devicePixelRatio = originalRatio;
    });
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(320, 568); // iPhone SE-class width

    await tester.pumpWidget(MaterialApp(
      home: IncomingCallFullscreenBanner(
        session: const CallSessionInfo(
          callId: 'c3',
          peerId: 'peer3',
          incoming: true,
          videoEnabled: false,
          audioEnabled: true,
        ),
        peerName: 'Узкий Экран',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.text('Отклонить'), findsOneWidget);
    expect(find.text('Принять'), findsOneWidget);
  });
}
