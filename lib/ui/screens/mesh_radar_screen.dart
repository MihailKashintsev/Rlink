import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/contact.dart';
import '../../services/ble_service.dart';
import '../../services/chat_storage_service.dart';
import '../widgets/avatar_widget.dart';
import 'chat_screen.dart';

/// Visual "who's nearby" view: direct BLE peers close to the center, known
/// contacts reachable only through the mesh further out, positioned by
/// roughly how many hops away their last profile broadcast came from (see
/// BleService.hopsAwayFor). Something WhatsApp/Telegram fundamentally can't
/// show — they have no mesh, only a server.
class MeshRadarScreen extends StatefulWidget {
  const MeshRadarScreen({super.key});

  @override
  State<MeshRadarScreen> createState() => _MeshRadarScreenState();
}

class _RadarPeer {
  final String peerId;
  final String label;
  final int color;
  final String emoji;
  final String? imagePath;
  final bool direct;
  final int? rssi;
  final int? hops;
  const _RadarPeer({
    required this.peerId,
    required this.label,
    required this.color,
    required this.emoji,
    required this.imagePath,
    required this.direct,
    this.rssi,
    this.hops,
  });
}

class _MeshRadarScreenState extends State<MeshRadarScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep;
  List<Contact> _contacts = [];

  @override
  void initState() {
    super.initState();
    _sweep = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
    BleService.instance.peersCount.addListener(_onChanged);
    BleService.instance.peerMappingsVersion.addListener(_onChanged);
    _loadContacts();
  }

  @override
  void dispose() {
    BleService.instance.peersCount.removeListener(_onChanged);
    BleService.instance.peerMappingsVersion.removeListener(_onChanged);
    _sweep.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadContacts() async {
    final list = await ChatStorageService.instance.getContacts();
    if (!mounted) return;
    setState(() => _contacts = list);
  }

  List<_RadarPeer> _buildPeers() {
    final direct = BleService.instance.connectedPeerIds.toSet();
    final byId = {for (final c in _contacts) c.publicKeyHex: c};
    final peers = <_RadarPeer>[];

    for (final peerId in direct) {
      final c = byId[peerId];
      peers.add(_RadarPeer(
        peerId: peerId,
        label: c?.nickname.isNotEmpty == true
            ? c!.nickname
            : '${peerId.substring(0, peerId.length.clamp(0, 6))}…',
        color: c?.avatarColor ?? peerId.hashCode,
        emoji: c?.avatarEmoji ?? '',
        imagePath: c?.avatarImagePath,
        direct: true,
        rssi: BleService.instance.getRssi(peerId),
      ));
    }

    for (final c in _contacts) {
      if (direct.contains(c.publicKeyHex)) continue;
      final hops = BleService.instance.hopsAwayFor(c.publicKeyHex);
      if (hops == null) continue;
      peers.add(_RadarPeer(
        peerId: c.publicKeyHex,
        label: c.nickname.isNotEmpty
            ? c.nickname
            : '${c.publicKeyHex.substring(0, 6)}…',
        color: c.avatarColor,
        emoji: c.avatarEmoji,
        imagePath: c.avatarImagePath,
        direct: false,
        hops: hops,
      ));
    }

    peers.sort((a, b) => a.peerId.compareTo(b.peerId));
    return peers;
  }

  /// Normalized radius (0..1) within the radar for one peer. Direct peers
  /// live in the inner half, positioned by signal strength; mesh-only peers
  /// live in the outer half, positioned by hop count.
  double _radiusFor(_RadarPeer p) {
    if (p.direct) {
      final rssi = p.rssi;
      if (rssi == null) return 0.35;
      // Typical BLE range: -40dBm (very close) .. -95dBm (edge of range).
      final t = ((rssi + 40).abs() / 55).clamp(0.0, 1.0);
      return 0.12 + t * 0.35;
    }
    final hops = (p.hops ?? 2).clamp(2, 6);
    return 0.55 + (hops - 2) / 4 * 0.42;
  }

  void _openChat(_RadarPeer p) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          peerId: p.peerId,
          peerNickname: p.label,
          peerAvatarColor: p.color,
          peerAvatarEmoji: p.emoji,
          peerAvatarImagePath: p.imagePath,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final peers = _buildPeers();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Радар mesh-сети'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
            onPressed: _loadContacts,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final side =
                    math.min(constraints.maxWidth, constraints.maxHeight) *
                        0.92;
                final radius = side / 2;
                return Center(
                  child: SizedBox(
                    width: side,
                    height: side,
                    child: AnimatedBuilder(
                      animation: _sweep,
                      builder: (context, _) => CustomPaint(
                        painter: _RadarPainter(
                          color: cs.primary,
                          sweepAngle: _sweep.value * 2 * math.pi,
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            _CenterDot(color: cs.primary),
                            for (final p in peers)
                              _peerDot(p, radius, peers.indexOf(p),
                                  peers.length),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (peers.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Text('Никого не видно поблизости',
                  style: TextStyle(color: cs.onSurfaceVariant)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Legend(
                    color: cs.primary, label: 'Напрямую по Bluetooth'),
                const SizedBox(width: 20),
                _Legend(
                    color: cs.onSurfaceVariant, label: 'Через сеть (mesh)'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _peerDot(_RadarPeer p, double radius, int index, int total) {
    final angle = (2 * math.pi * index / math.max(total, 1)) - math.pi / 2;
    final r = _radiusFor(p) * radius;
    final dx = radius + r * math.cos(angle);
    final dy = radius + r * math.sin(angle);
    return Positioned(
      left: dx - 22,
      top: dy - 22,
      child: GestureDetector(
        onTap: () => _openChat(p),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: p.direct ? Colors.greenAccent : Colors.white24,
                  width: 2,
                ),
              ),
              child: AvatarWidget(
                initials: p.label.isNotEmpty ? p.label[0] : '?',
                color: p.color,
                emoji: p.emoji,
                imagePath: p.imagePath,
                size: 36,
              ),
            ),
            const SizedBox(height: 2),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 64),
              child: Text(
                p.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CenterDot extends StatelessWidget {
  final Color color;
  const _CenterDot({required this.color});

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(
                    color: color.withValues(alpha: 0.6),
                    blurRadius: 12,
                    spreadRadius: 4),
              ],
            ),
          ),
          const SizedBox(height: 2),
          const Text('Я', style: TextStyle(fontSize: 10, color: Colors.white)),
        ],
      );
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  const _Legend({required this.color, required this.label});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      );
}

class _RadarPainter extends CustomPainter {
  final Color color;
  final double sweepAngle;
  _RadarPainter({required this.color, required this.sweepAngle});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final ringPaint = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final f in [0.25, 0.5, 0.75, 1.0]) {
      canvas.drawCircle(center, radius * f, ringPaint);
    }

    final sweepPaint = Paint()
      ..shader = SweepGradient(
        colors: [color.withValues(alpha: 0.0), color.withValues(alpha: 0.25)],
        startAngle: 0,
        endAngle: math.pi / 2,
        transform: GradientRotation(sweepAngle),
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, sweepPaint);
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      oldDelegate.sweepAngle != sweepAngle || oldDelegate.color != color;
}
