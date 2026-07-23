import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/contact.dart';
import '../../services/crypto_service.dart';
import '../../services/profile_service.dart';
import '../../services/rlink_deep_link_service.dart';
import '../../utils/rlink_deep_link.dart';
import '../rlink_nav_routes.dart';
import '../screens/chat_screen.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/security_visuals.dart';

/// True on platforms where the camera QR scanner is available.
bool get _scanSupported =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Bottom sheet: "show my QR" / "scan a QR" — the two ways to swap contacts.
Future<void> showAddByQrSheet(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: cs.surface,
    builder: (sheetCtx) {
      Widget option({
        required IconData icon,
        required String title,
        required String subtitle,
        required VoidCallback onTap,
      }) =>
          ListTile(
            leading: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: cs.primary),
            ),
            title: Text(title,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(subtitle),
            onTap: () {
              Navigator.pop(sheetCtx);
              onTap();
            },
          );

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 4),
            Text('Знакомство по QR',
                style: Theme.of(sheetCtx).textTheme.titleMedium),
            const SizedBox(height: 12),
            option(
              icon: Icons.qr_code_2_rounded,
              title: 'Мой QR-код',
              subtitle: 'Покажите его, чтобы вас добавили',
              onTap: () => Navigator.of(context)
                  .push(rlinkPushRoute(const MyQrScreen())),
            ),
            if (_scanSupported)
              option(
                icon: Icons.qr_code_scanner_rounded,
                title: 'Сканировать QR',
                subtitle: 'Наведите камеру на чужой код',
                onTap: () => Navigator.of(context)
                    .push(rlinkPushRoute(const QrScanScreen())),
              )
            else
              option(
                icon: Icons.link_rounded,
                title: 'Добавить по ссылке',
                subtitle: 'Вставьте rlink-ссылку контакта',
                onTap: () => _pasteLinkDialog(context),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// My QR — an animated card others scan to add me.
// ─────────────────────────────────────────────────────────────────────────────

class MyQrScreen extends StatefulWidget {
  const MyQrScreen({super.key});

  @override
  State<MyQrScreen> createState() => _MyQrScreenState();
}

class _MyQrScreenState extends State<MyQrScreen>
    with TickerProviderStateMixin {
  late final AnimationController _revealCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  // Strong ease-out — the card lands quickly then settles.
  late final Animation<double> _cardT = CurvedAnimation(
    parent: _revealCtrl,
    curve: const Interval(0, 0.6, curve: Cubic(0.23, 1, 0.32, 1)),
  );
  // A one-shot light sweep drawn over the QR as it appears.
  late final Animation<double> _sweep = CurvedAnimation(
    parent: _revealCtrl,
    curve: const Interval(0.35, 1, curve: Curves.easeInOut),
  );

  @override
  void dispose() {
    _revealCtrl.dispose();
    super.dispose();
  }

  String? get _link {
    final p = ProfileService.instance.profile;
    if (p == null) return null;
    return RlinkDeepLink.userUri(
      publicKeyHex: p.publicKeyHex,
      x25519Key: CryptoService.instance.x25519PublicKeyBase64,
      nickname: p.nickname,
      username: p.username,
      avatarColor: p.avatarColor,
      avatarEmoji: p.avatarEmoji,
      statusEmoji: p.statusEmoji,
    ).toString();
  }

  Future<void> _share() async {
    final link = _link;
    if (link == null) return;
    HapticFeedback.selectionClick();
    final p = ProfileService.instance.profile;
    await Share.share(
      'Добавьте меня в Rlink${p != null ? ' — ${p.nickname}' : ''}\n$link',
      sharePositionOrigin:
          RlinkDeepLink.sharePositionOriginFromContext(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = ProfileService.instance.profile;
    final link = _link;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        title: const Text('Мой QR-код'),
        actions: [
          if (link != null)
            IconButton(
              tooltip: 'Поделиться',
              icon: const Icon(Icons.ios_share_rounded),
              onPressed: _share,
            ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 24),
          child: (link == null || p == null)
              ? const Text('Профиль ещё не создан')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedBuilder(
                      animation: _revealCtrl,
                      builder: (_, child) {
                        final t = _cardT.value;
                        return Opacity(
                          opacity: t.clamp(0.0, 1.0),
                          child: Transform.scale(
                            scale: 0.86 + 0.14 * t,
                            child: child,
                          ),
                        );
                      },
                      child: _QrCard(
                        data: link,
                        sweep: _sweep,
                        initials: p.initials,
                        avatarColor: p.avatarColor,
                        avatarEmoji: p.avatarEmoji,
                        avatarImagePath: p.avatarImagePath,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      p.nickname,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                    if (p.username.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text('@${p.username}',
                          style: TextStyle(color: cs.onSurfaceVariant)),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      'Наведите камеру собеседника на этот код,\nчтобы обменяться контактами',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: cs.onSurfaceVariant, fontSize: 13),
                    ),
                    if (_scanSupported) ...[
                      const SizedBox(height: 24),
                      FilledButton.tonalIcon(
                        onPressed: () => Navigator.of(context).pushReplacement(
                            rlinkPushRoute(const QrScanScreen())),
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: const Text('Сканировать чужой код'),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

/// White rounded card holding the QR with the user's avatar in the middle and a
/// one-shot diagonal light sweep on reveal.
class _QrCard extends StatelessWidget {
  final String data;
  final Animation<double> sweep;
  final String initials;
  final int avatarColor;
  final String avatarEmoji;
  final String? avatarImagePath;

  const _QrCard({
    required this.data,
    required this.sweep,
    required this.initials,
    required this.avatarColor,
    required this.avatarEmoji,
    this.avatarImagePath,
  });

  @override
  Widget build(BuildContext context) {
    const size = 240.0;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            QrImageView(
              data: data,
              size: size,
              padding: EdgeInsets.zero,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.circle,
                color: Color(0xFF111111),
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.circle,
                color: Color(0xFF111111),
              ),
              errorCorrectionLevel: QrErrorCorrectLevel.H,
            ),
            // Avatar coin in the center (H-level EC tolerates the occlusion).
            // AvatarWidget is web-safe (handles OPFS/blob photos), unlike a raw
            // dart:io File — that's why the photo was missing on web.
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 4),
              ),
              child: AvatarWidget(
                initials: initials,
                color: avatarColor,
                emoji: avatarEmoji,
                imagePath: avatarImagePath,
                size: 50,
              ),
            ),
            // One-shot diagonal sweep on reveal.
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: sweep,
                  builder: (_, __) => CustomPaint(
                    painter: _SweepPainter(sweep.value),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SweepPainter extends CustomPainter {
  final double t; // 0..1
  _SweepPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    // A soft light band travelling top-left → bottom-right, once.
    final d = size.width + size.height;
    final pos = d * t;
    const band = 46.0;
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRect(rect);
    final paint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0x00FFFFFF), Color(0x66FFFFFF), Color(0x00FFFFFF)],
      ).createShader(Rect.fromLTWH(pos - band, 0, band * 2, size.height))
      ..blendMode = BlendMode.plus;
    canvas.save();
    canvas.translate(pos, 0);
    canvas.rotate(math.pi / 4);
    canvas.drawRect(
        Rect.fromLTWH(-band, -size.height, band * 2, size.height * 3), paint);
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.t != t;
}

// ─────────────────────────────────────────────────────────────────────────────
// Scanner — camera + animated frame, resolves a contact from a QR.
// ─────────────────────────────────────────────────────────────────────────────

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen>
    with SingleTickerProviderStateMixin {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  late final AnimationController _lineCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  bool _handled = false;
  Contact? _found;

  @override
  void dispose() {
    _lineCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null || raw.isEmpty) continue;
      final uri = Uri.tryParse(raw.trim());
      final link = uri == null ? null : RlinkDeepLink.parseUser(uri);
      if (link != null) {
        _handled = true;
        unawaited(_accept(link));
        return;
      }
    }
  }

  Future<void> _accept(RlinkUserLink link) async {
    HapticFeedback.mediumImpact();
    unawaited(_controller.stop());
    final contact = await RlinkDeepLinkService.instance.applyUserLink(link);
    if (!mounted) return;
    if (contact == null) {
      // Own code — let them keep scanning.
      _handled = false;
      unawaited(_controller.start());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Это ваш собственный QR-код')),
      );
      return;
    }
    setState(() => _found = contact);
  }

  void _onSuccessDone() {
    final c = _found;
    if (!mounted || c == null) return;
    Navigator.of(context).pushReplacement(rlinkPushRoute(ChatScreen(
      peerId: c.publicKeyHex,
      peerNickname: c.nickname,
      peerAvatarColor: c.avatarColor,
      peerAvatarEmoji: c.avatarEmoji,
    )));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Сканирование'),
        actions: [
          IconButton(
            tooltip: 'Вспышка',
            icon: const Icon(Icons.flash_on_rounded),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            tooltip: 'Сменить камеру',
            icon: const Icon(Icons.cameraswitch_rounded),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error, child) => _CameraError(error),
          ),
          // Dim surround + clear window + animated frame.
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _lineCtrl,
              builder: (_, __) => CustomPaint(
                painter: _ScannerOverlayPainter(_lineCtrl.value),
                size: Size.infinite,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 60,
            child: Column(
              children: [
                const Text(
                  'Наведите на QR-код собеседника',
                  style: TextStyle(color: Colors.white, fontSize: 15),
                ),
                const SizedBox(height: 14),
                TextButton.icon(
                  onPressed: () => _pasteLinkDialog(context),
                  icon: const Icon(Icons.link_rounded, color: Colors.white70),
                  label: const Text('Ввести код вручную',
                      style: TextStyle(color: Colors.white70)),
                ),
              ],
            ),
          ),
          // Success celebration — reuses the unlock seal for one visual language.
          if (_found != null)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.55),
                child: LockSuccessOverlay(onCompleted: _onSuccessDone),
              ),
            ),
        ],
      ),
    );
  }
}

class _ScannerOverlayPainter extends CustomPainter {
  final double t; // 0..1 scan-line position
  _ScannerOverlayPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height) * 0.72;
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: side,
      height: side,
    );
    final rr = RRect.fromRectAndRadius(rect, const Radius.circular(24));

    // Dim everything outside the window.
    final dim = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(rr)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.55));

    // Corner brackets.
    const cl = 30.0; // corner length
    final bracket = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    void corner(Offset o, Offset hx, Offset vy) {
      canvas.drawLine(o, o + hx, bracket);
      canvas.drawLine(o, o + vy, bracket);
    }

    corner(rect.topLeft, const Offset(cl, 0), const Offset(0, cl));
    corner(rect.topRight, const Offset(-cl, 0), const Offset(0, cl));
    corner(rect.bottomLeft, const Offset(cl, 0), const Offset(0, -cl));
    corner(rect.bottomRight, const Offset(-cl, 0), const Offset(0, -cl));

    // Travelling scan line with a soft glow.
    final y = rect.top + rect.height * t;
    final grad = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0x0030A46C), Color(0xCC30A46C), Color(0x0030A46C)],
      ).createShader(Rect.fromLTWH(rect.left, y - 14, rect.width, 28));
    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawRect(
        Rect.fromLTWH(rect.left, y - 14, rect.width, 28), grad);
    canvas.drawLine(
      Offset(rect.left + 8, y),
      Offset(rect.right - 8, y),
      Paint()
        ..color = const Color(0xFF30A46C)
        ..strokeWidth = 2,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScannerOverlayPainter old) => old.t != t;
}

class _CameraError extends StatelessWidget {
  final MobileScannerException error;
  const _CameraError(this.error);

  @override
  Widget build(BuildContext context) {
    final denied =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_rounded,
                  color: Colors.white54, size: 48),
              const SizedBox(height: 16),
              Text(
                denied
                    ? 'Нет доступа к камере.\nРазрешите камеру в настройках.'
                    : 'Камера недоступна.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                onPressed: () => _pasteLinkDialog(context),
                icon: const Icon(Icons.link_rounded),
                label: const Text('Ввести код вручную'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Manual paste fallback (desktop without a camera, or denied permission).
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _pasteLinkDialog(BuildContext context) async {
  final ctrl = TextEditingController();
  final link = await showDialog<String>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: const Text('Добавить по ссылке'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLines: 2,
        decoration: const InputDecoration(
          hintText: 'rlink://user/…',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dctx),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dctx, ctrl.text.trim()),
          child: const Text('Добавить'),
        ),
      ],
    ),
  );
  if (link == null || link.isEmpty || !context.mounted) return;
  final uri = Uri.tryParse(link);
  final parsed = uri == null ? null : RlinkDeepLink.parseUser(uri);
  if (parsed == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Не похоже на ссылку контакта Rlink')),
    );
    return;
  }
  final contact = await RlinkDeepLinkService.instance.applyUserLink(parsed);
  if (!context.mounted) return;
  if (contact == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Это ваш собственный код')),
    );
    return;
  }
  Navigator.of(context).push(rlinkPushRoute(ChatScreen(
    peerId: contact.publicKeyHex,
    peerNickname: contact.nickname,
    peerAvatarColor: contact.avatarColor,
    peerAvatarEmoji: contact.avatarEmoji,
  )));
}
