import 'package:flutter/material.dart';

import '../../l10n/app_l10n.dart';
import '../../services/vpn_status_service.dart';

/// Slim heads-up shown while a VPN is active; dismissed until the VPN is
/// switched off and on again.
class VpnNoticeBanner extends StatefulWidget {
  const VpnNoticeBanner({super.key});

  @override
  State<VpnNoticeBanner> createState() => _VpnNoticeBannerState();
}

class _VpnNoticeBannerState extends State<VpnNoticeBanner> {
  static bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: VpnStatusService.instance.active,
      builder: (context, on, _) {
        if (!on) {
          _dismissed = false; // re-arm for the next time a VPN is enabled
          return const SizedBox.shrink();
        }
        if (_dismissed) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        return Container(
          margin: const EdgeInsets.fromLTRB(10, 4, 10, 6),
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          decoration: BoxDecoration(
            color: cs.tertiaryContainer.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.vpn_lock_rounded, size: 18, color: cs.onTertiaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  AppL10n.t(
                      'Включён VPN — с ним возможны небольшие неполадки в работе приложения (сообщения, звонки, синхронизация).'),
                  style: TextStyle(fontSize: 12.5, color: cs.onTertiaryContainer),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close_rounded,
                    size: 18, color: cs.onTertiaryContainer),
                onPressed: () => setState(() => _dismissed = true),
              ),
            ],
          ),
        );
      },
    );
  }
}
