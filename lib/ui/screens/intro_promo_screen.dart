import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_l10n.dart';
import '../../services/app_settings.dart';

/// A fully programmatic, theme-aware, localized promo / onboarding played on
/// first launch (and from Settings → «Как устроен Rlink»). Because it's built
/// from live widgets it always matches the user's palette, theme and language.
class IntroPromoScreen extends StatefulWidget {
  /// When true (first launch) marks the intro as seen on finish.
  final bool markSeenOnFinish;
  const IntroPromoScreen({super.key, this.markSeenOnFinish = true});

  @override
  State<IntroPromoScreen> createState() => _IntroPromoScreenState();
}

enum _Art {
  welcome,
  universal,
  messages,
  privacy,
  bots,
  groups,
  channels,
  stories,
  bluetooth,
  server,
  calls,
  cta,
}

class _Scene {
  final _Art art;
  final String titleKey;
  final String subKey;
  const _Scene(this.art, this.titleKey, this.subKey);
}

const _scenes = <_Scene>[
  _Scene(_Art.welcome, 'intro_welcome_title', 'intro_welcome_sub'),
  _Scene(_Art.universal, 'intro_universal_title', 'intro_universal_sub'),
  _Scene(_Art.messages, 'intro_messages_title', 'intro_messages_sub'),
  _Scene(_Art.privacy, 'intro_privacy_title', 'intro_privacy_sub'),
  _Scene(_Art.bots, 'intro_bots_title', 'intro_bots_sub'),
  _Scene(_Art.groups, 'intro_groups_title', 'intro_groups_sub'),
  _Scene(_Art.channels, 'intro_channels_title', 'intro_channels_sub'),
  _Scene(_Art.stories, 'intro_stories_title', 'intro_stories_sub'),
  _Scene(_Art.bluetooth, 'intro_bluetooth_title', 'intro_bluetooth_sub'),
  _Scene(_Art.server, 'intro_server_title', 'intro_server_sub'),
  _Scene(_Art.calls, 'intro_calls_title', 'intro_calls_sub'),
  _Scene(_Art.cta, 'intro_welcome_title', 'intro_start'),
];

class _IntroPromoScreenState extends State<IntroPromoScreen>
    with TickerProviderStateMixin {
  // Per-scene progress (0..1), auto-advances on complete.
  late final AnimationController _seg = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  )..addStatusListener(_onSeg);
  // Continuous ambient motion.
  late final AnimationController _amb = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  int _index = 0;

  @override
  void initState() {
    super.initState();
    _seg.forward();
  }

  @override
  void dispose() {
    _seg.dispose();
    _amb.dispose();
    super.dispose();
  }

  void _onSeg(AnimationStatus s) {
    if (s != AnimationStatus.completed) return;
    if (_index >= _scenes.length - 1) return; // wait on CTA
    setState(() => _index++);
    _seg
      ..reset()
      ..forward();
  }

  void _next() {
    if (_index >= _scenes.length - 1) {
      _finish();
      return;
    }
    setState(() => _index++);
    _seg
      ..reset()
      ..forward();
  }

  void _prev() {
    if (_index == 0) {
      _seg
        ..reset()
        ..forward();
      return;
    }
    setState(() => _index--);
    _seg
      ..reset()
      ..forward();
  }

  Future<void> _finish() async {
    if (widget.markSeenOnFinish) {
      await AppSettings.instance.setHasSeenIntro(true);
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final scene = _scenes[_index];
    final isLast = _index == _scenes.length - 1;
    return Scaffold(
      body: AnimatedBuilder(
        animation: Listenable.merge([_seg, _amb]),
        builder: (context, _) {
          final phase = _amb.value * 2 * math.pi;
          return Stack(
            children: [
              // Themed background that adapts to the user's palette.
              _Background(cs: cs, phase: phase),
              // Tap zones: left = back, right = next.
              Positioned.fill(
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _prev,
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _next,
                      ),
                    ),
                  ],
                ),
              ),
              // Center art + texts.
              SafeArea(
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    _ProgressSegments(
                      count: _scenes.length,
                      index: _index,
                      progress: _seg.value,
                      cs: cs,
                    ),
                    Expanded(
                      child: Center(
                        child: _SceneView(
                          // Re-key per scene so entrance animations replay.
                          key: ValueKey(_index),
                          scene: scene,
                          phase: phase,
                          cs: cs,
                        ),
                      ),
                    ),
                    // Bottom controls.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                      child: isLast
                          ? SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: _finish,
                                style: FilledButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 18),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                ),
                                child: Text(
                                  AppL10n.t('intro_start'),
                                  style: const TextStyle(
                                      fontSize: 18, fontWeight: FontWeight.w600),
                                ),
                              ),
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                TextButton(
                                  onPressed: _finish,
                                  child: Text(
                                    AppL10n.t('intro_skip'),
                                    style: TextStyle(
                                        color: cs.onSurface
                                            .withValues(alpha: 0.6),
                                        fontSize: 16),
                                  ),
                                ),
                                FilledButton.tonal(
                                  onPressed: _next,
                                  child: Text(AppL10n.t('intro_next')),
                                ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Background (theme-aware) ─────────────────────────────────────────────────
class _Background extends StatelessWidget {
  final ColorScheme cs;
  final double phase;
  const _Background({required this.cs, required this.phase});

  @override
  Widget build(BuildContext context) {
    final base = cs.surface;
    final a = math.sin(phase);
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: base)),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(a * 0.18, -0.65 + a * 0.06),
                radius: 1.25,
                colors: [
                  cs.primary.withValues(alpha: 0.32),
                  cs.primary.withValues(alpha: 0.10),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.4, 1.0],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(-a * 0.25, 0.7),
                radius: 1.1,
                colors: [
                  cs.tertiary.withValues(alpha: 0.16),
                  Colors.transparent,
                ],
                stops: const [0.0, 1.0],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Progress segments ───────────────────────────────────────────────────────
class _ProgressSegments extends StatelessWidget {
  final int count;
  final int index;
  final double progress;
  final ColorScheme cs;
  const _ProgressSegments({
    required this.count,
    required this.index,
    required this.progress,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: List.generate(count, (i) {
          final v = i < index
              ? 1.0
              : i == index
                  ? progress
                  : 0.0;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: v,
                  minHeight: 4,
                  backgroundColor: cs.onSurface.withValues(alpha: 0.18),
                  valueColor: AlwaysStoppedAnimation(cs.primary),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ── Scene view (art + texts with entrance animation) ────────────────────────
class _SceneView extends StatefulWidget {
  final _Scene scene;
  final double phase;
  final ColorScheme cs;
  const _SceneView({
    super.key,
    required this.scene,
    required this.phase,
    required this.cs,
  });

  @override
  State<_SceneView> createState() => _SceneViewState();
}

class _SceneViewState extends State<_SceneView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  )..forward();

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.cs;
    return AnimatedBuilder(
      animation: _in,
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform(_in.value);
        final tText = Curves.easeOutCubic
            .transform((_in.value * 1.4 - 0.25).clamp(0.0, 1.0));
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(
              opacity: t,
              child: Transform.scale(
                scale: 0.9 + 0.1 * t,
                child: SizedBox(
                  width: 300,
                  height: 300,
                  child: _SceneArt(
                    art: widget.scene.art,
                    t: t,
                    phase: widget.phase,
                    cs: cs,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 44),
            Opacity(
              opacity: tText,
              child: Transform.translate(
                offset: Offset(0, 18 * (1 - tText)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    children: [
                      Text(
                        AppL10n.t(widget.scene.titleKey),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: widget.scene.art == _Art.welcome ||
                                  widget.scene.art == _Art.cta
                              ? 46
                              : 30,
                          fontWeight: FontWeight.w700,
                          letterSpacing:
                              widget.scene.art == _Art.welcome ? 3 : 0.2,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        AppL10n.t(widget.scene.subKey),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 19,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── The illustrations (built from live widgets, theme coloured) ─────────────
class _SceneArt extends StatelessWidget {
  final _Art art;
  final double t;
  final double phase;
  final ColorScheme cs;
  const _SceneArt({
    required this.art,
    required this.t,
    required this.phase,
    required this.cs,
  });

  Widget _badge(IconData icon, {double size = 200, double iconSize = 96}) {
    final pulse = 0.5 + 0.5 * math.sin(phase);
    return Center(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [cs.primary, Color.lerp(cs.primary, cs.tertiary, 0.6)!],
          ),
          boxShadow: [
            BoxShadow(
              color: cs.primary.withValues(alpha: 0.35 + 0.2 * pulse),
              blurRadius: 50 + 20 * pulse,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Icon(icon, size: iconSize, color: cs.onPrimary),
      ),
    );
  }

  Widget _rings(Widget child) {
    // Fixed 200x200 footprint so the expanding rings (which grow past 300px) do
    // NOT change this widget's layout size each frame — otherwise anything placed
    // below it in a Column (e.g. the "без телефона" plashka) drifts up/down as the
    // rings pulse. OverflowBox lets the rings paint larger while the Stack stays put.
    return SizedBox(
      width: 200,
      height: 200,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          for (var i = 0; i < 3; i++)
            Builder(builder: (_) {
              final p = ((phase / (2 * math.pi) + i * 0.33) % 1.0);
              final d = 180 + p * 150;
              return OverflowBox(
                maxWidth: double.infinity,
                maxHeight: double.infinity,
                child: Container(
                  width: d,
                  height: d,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: cs.primary.withValues(alpha: (1 - p) * 0.4),
                      width: 2,
                    ),
                  ),
                ),
              );
            }),
          child,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    switch (art) {
      case _Art.welcome:
      case _Art.cta:
        return _rings(
          Container(
            width: 168,
            height: 168,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [cs.primary, Color.lerp(cs.primary, cs.tertiary, 0.7)!],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                    color: cs.primary.withValues(alpha: 0.45),
                    blurRadius: 60,
                    spreadRadius: 4),
              ],
            ),
            child: Icon(Icons.bolt_rounded, size: 92, color: cs.onPrimary),
          ),
        );

      case _Art.universal:
        return _DeviceFan(cs: cs, t: t);

      case _Art.messages:
        return _MessagesArt(cs: cs, t: t);

      case _Art.privacy:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _rings(
              Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      cs.primary,
                      Color.lerp(cs.primary, cs.tertiary, 0.7)!
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                        color: cs.primary.withValues(alpha: 0.4),
                        blurRadius: 50),
                  ],
                ),
                child: Icon(Icons.verified_user_rounded,
                    size: 84, color: cs.onPrimary),
              ),
            ),
            const SizedBox(height: 26),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: cs.primary.withValues(alpha: 0.5), width: 1.4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.phonelink_erase_rounded,
                      color: cs.primary, size: 22),
                  const SizedBox(width: 8),
                  Text(
                    AppL10n.t('intro_privacy_title'),
                    style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w600,
                        fontSize: 16),
                  ),
                ],
              ),
            ),
          ],
        );

      case _Art.bots:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _badge(Icons.smart_toy_rounded, size: 180, iconSize: 86),
            const SizedBox(height: 22),
            Wrap(
              spacing: 10,
              children: ['/start', '/help', '/new'].map((c) {
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: cs.primary.withValues(alpha: 0.5), width: 1.4),
                  ),
                  child: Text(c,
                      style: TextStyle(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                          fontSize: 17)),
                );
              }).toList(),
            ),
          ],
        );

      case _Art.groups:
        return _AvatarCluster(cs: cs, phase: phase);

      case _Art.channels:
        return _badge(Icons.campaign_rounded, size: 196, iconSize: 100);

      case _Art.stories:
        return _StoriesArt(cs: cs, phase: phase);

      case _Art.bluetooth:
        return _ConnectivityArt(cs: cs, phase: phase, server: false);

      case _Art.server:
        return _ConnectivityArt(cs: cs, phase: phase, server: true);

      case _Art.calls:
        return _CallsArt(cs: cs, phase: phase);
    }
  }
}

// ── Universality: phone + tablet + laptop ───────────────────────────────────
class _DeviceFan extends StatelessWidget {
  final ColorScheme cs;
  final double t;
  const _DeviceFan({required this.cs, required this.t});

  Widget _frame(double w, double h, IconData icon) => Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.primary.withValues(alpha: 0.6), width: 2),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.4), blurRadius: 24),
          ],
        ),
        child: Icon(icon, color: cs.primary, size: w * 0.42),
      );

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Transform.translate(
          offset: Offset(-92 * t, 14),
          child: Transform.rotate(
            angle: -0.18,
            child: _frame(150, 100, Icons.laptop_mac_rounded),
          ),
        ),
        Transform.translate(
          offset: Offset(96 * t, 6),
          child: Transform.rotate(
            angle: 0.16,
            child: _frame(116, 150, Icons.tablet_mac_rounded),
          ),
        ),
        Transform.translate(
          offset: Offset(0, -10 * t),
          child: _frame(96, 184, Icons.smartphone_rounded),
        ),
      ],
    );
  }
}

// ── Messages: stacked bubbles + lock ────────────────────────────────────────
class _MessagesArt extends StatelessWidget {
  final ColorScheme cs;
  final double t;
  const _MessagesArt({required this.cs, required this.t});

  Widget _bubble(bool out, double w) => Align(
        alignment: out ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: w,
          height: 40,
          decoration: BoxDecoration(
            color: out ? cs.primary : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(20),
              topRight: const Radius.circular(20),
              bottomLeft: Radius.circular(out ? 20 : 6),
              bottomRight: Radius.circular(out ? 6 : 20),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _bubble(false, 170),
          const SizedBox(height: 12),
          _bubble(true, 200),
          const SizedBox(height: 12),
          _bubble(false, 130),
          const SizedBox(height: 24),
          Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cs.primary.withValues(alpha: 0.16),
              border:
                  Border.all(color: cs.primary.withValues(alpha: 0.6), width: 2),
            ),
            child: Icon(Icons.lock_rounded, color: cs.primary, size: 36),
          ),
        ],
      ),
    );
  }
}

// ── Groups: cluster of avatars ──────────────────────────────────────────────
class _AvatarCluster extends StatelessWidget {
  final ColorScheme cs;
  final double phase;
  const _AvatarCluster({required this.cs, required this.phase});

  @override
  Widget build(BuildContext context) {
    final colors = [
      const Color(0xFF7C4DFF),
      const Color(0xFFEC407A),
      const Color(0xFFFFA726),
      const Color(0xFF26A69A),
      cs.primary,
    ];
    final emojis = ['🦊', '🐱', '🦉', '🐧', '🙂'];
    return SizedBox(
      width: 260,
      height: 260,
      child: Stack(
        alignment: Alignment.center,
        children: [
          for (var i = 0; i < 5; i++)
            Builder(builder: (_) {
              final ang = (i / 5) * 2 * math.pi + phase * 0.15;
              final r = 92.0;
              return Transform.translate(
                offset: Offset(math.cos(ang) * r, math.sin(ang) * r),
                child: _av(colors[i], emojis[i], 76),
              );
            }),
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cs.primary,
              boxShadow: [
                BoxShadow(
                    color: cs.primary.withValues(alpha: 0.4), blurRadius: 30),
              ],
            ),
            child: Icon(Icons.groups_rounded, color: cs.onPrimary, size: 50),
          ),
        ],
      ),
    );
  }

  Widget _av(Color c, String e, double s) => Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c,
          border: Border.all(color: cs.surface, width: 3),
        ),
        alignment: Alignment.center,
        child: Text(e, style: TextStyle(fontSize: s * 0.5)),
      );
}

// ── Stories: progress ring + camera ─────────────────────────────────────────
class _StoriesArt extends StatelessWidget {
  final ColorScheme cs;
  final double phase;
  const _StoriesArt({required this.cs, required this.phase});

  @override
  Widget build(BuildContext context) {
    final p = (phase / (2 * math.pi)) % 1.0;
    return SizedBox(
      width: 220,
      height: 220,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 200,
            height: 200,
            child: CircularProgressIndicator(
              value: p,
              strokeWidth: 7,
              backgroundColor: cs.onSurface.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation(cs.primary),
              strokeCap: StrokeCap.round,
            ),
          ),
          Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [cs.primary, Color.lerp(cs.primary, cs.tertiary, 0.7)!],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Icon(Icons.auto_stories_rounded,
                color: cs.onPrimary, size: 76),
          ),
        ],
      ),
    );
  }
}

// ── Connectivity: two phones + Bluetooth / server link ──────────────────────
class _ConnectivityArt extends StatelessWidget {
  final ColorScheme cs;
  final double phase;
  final bool server;
  const _ConnectivityArt({
    required this.cs,
    required this.phase,
    required this.server,
  });

  @override
  Widget build(BuildContext context) {
    final accent = server ? cs.primary : const Color(0xFF3B9DFF);
    return SizedBox(
      width: 300,
      height: 220,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // pulse rings
          for (var i = 0; i < 3; i++)
            Builder(builder: (_) {
              final p = ((phase / (2 * math.pi) + i * 0.33) % 1.0);
              return Container(
                width: 70 + p * 150,
                height: 70 + p * 150,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: accent.withValues(alpha: (1 - p) * 0.45),
                      width: 2),
                ),
              );
            }),
          // left/right mini phones
          Positioned(
            left: 8,
            child: _phone(const Color(0xFF7C4DFF), '🦊'),
          ),
          Positioned(
            right: 8,
            child: _phone(const Color(0xFFEC407A), '🐱'),
          ),
          // center link badge
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.16),
              border: Border.all(color: accent.withValues(alpha: 0.6), width: 2),
            ),
            child: server
                ? Icon(Icons.cloud_rounded, color: accent, size: 50)
                : Icon(Icons.bluetooth_rounded, color: accent, size: 50),
          ),
        ],
      ),
    );
  }

  Widget _phone(Color c, String e) => Container(
        width: 64,
        height: 128,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.black.withValues(alpha: 0.4)),
        ),
        alignment: Alignment.center,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(shape: BoxShape.circle, color: c),
          alignment: Alignment.center,
          child: Text(e, style: const TextStyle(fontSize: 22)),
        ),
      );
}

// ── Calls: badge + waveform ─────────────────────────────────────────────────
class _CallsArt extends StatelessWidget {
  final ColorScheme cs;
  final double phase;
  const _CallsArt({required this.cs, required this.phase});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            for (var i = 0; i < 2; i++)
              Builder(builder: (_) {
                final p = ((phase / (2 * math.pi) + i * 0.5) % 1.0);
                return Container(
                  width: 150 + p * 90,
                  height: 150 + p * 90,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: cs.primary.withValues(alpha: (1 - p) * 0.4),
                        width: 2),
                  ),
                );
              }),
            Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    cs.primary,
                    Color.lerp(cs.primary, cs.tertiary, 0.7)!
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Icon(Icons.videocam_rounded,
                  color: cs.onPrimary, size: 70),
            ),
          ],
        ),
        const SizedBox(height: 30),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(21, (i) {
            final env = math.sin((i / 20) * math.pi);
            final h = 10 +
                52 *
                    env *
                    (0.4 +
                        0.6 *
                            (0.5 + 0.5 * math.sin(i * 0.8 + phase * 2)).abs());
            return Container(
              width: 5,
              height: h,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
        ),
      ],
    );
  }
}
