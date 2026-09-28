import 'package:flutter/material.dart';

import '../../services/call_service.dart';
import '../../l10n/app_l10n.dart';

/// App-wide pill shown while a 1:1 call is running but [CallScreen] isn't on
/// top (minimized via the chevron button to read/write in another chat) —
/// mirrors [GroupCallReturnPill]. One tap reopens the call screen.
class CallReturnPill extends StatelessWidget {
  final void Function() onTap;

  const CallReturnPill({super.key, required this.onTap});

  String _fmt(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final svc = CallService.instance;
    return ListenableBuilder(
      listenable:
          Listenable.merge([svc.phase, svc.screenOpen, svc.callElapsed]),
      builder: (context, _) {
        if (!svc.isBusy || svc.screenOpen.value) {
          return const SizedBox.shrink();
        }
        final session = svc.activeSession;
        final video = session?.videoEnabled ?? false;
        final label = switch (svc.phase.value) {
          CallPhase.connected => _fmt(svc.callElapsed.value),
          CallPhase.connecting => AppL10n.t('Соединение…'),
          CallPhase.ringing when session?.incoming ?? false =>
            AppL10n.t('Входящий звонок'),
          _ => AppL10n.t('Ждём ответа…'),
        };
        return SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Material(
                color: Colors.green.shade700,
                borderRadius: BorderRadius.circular(20),
                elevation: 4,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 7),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(video ? Icons.videocam : Icons.call,
                            size: 16, color: Colors.white),
                        const SizedBox(width: 8),
                        Text(
                          AppL10n.f('{0} · вернуться', [label]),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
