import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tick_sound.dart';

import '../../l10n/app_l10n.dart';

/// iPhone-style spinning date/time picker for "send later".
///
/// Returns the chosen [DateTime] (always in the future) or null on cancel.
Future<DateTime?> showWheelDateTimeSheet(
  BuildContext context, {
  DateTime? initial,
}) {
  return showModalBottomSheet<DateTime>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _WheelSheet(initial: initial),
  );
}

/// iPhone-style spinning day + month picker for a birthday. Returns "MM-DD"
/// (year isn't asked — a birthday only needs the day) or null on cancel.
Future<String?> showWheelBirthdaySheet(
  BuildContext context, {
  String? initialMonthDay,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _BirthdayWheelSheet(initial: initialMonthDay),
  );
}

class _BirthdayWheelSheet extends StatefulWidget {
  final String? initial;
  const _BirthdayWheelSheet({this.initial});

  @override
  State<_BirthdayWheelSheet> createState() => _BirthdayWheelSheetState();
}

class _BirthdayWheelSheetState extends State<_BirthdayWheelSheet> {
  static const _nom = [
    'Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль',
    'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь'
  ];
  static const _gen = [
    'января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля',
    'августа', 'сентября', 'октября', 'ноября', 'декабря'
  ];
  static const _maxDay = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

  int _dayIdx = 0; // 0..30
  int _monthIdx = 0; // 0..11

  @override
  void initState() {
    super.initState();
    final m = RegExp(r'(\d{2})-(\d{2})$').firstMatch(widget.initial ?? '');
    if (m != null) {
      _monthIdx = ((int.tryParse(m.group(1)!) ?? 1) - 1).clamp(0, 11);
      _dayIdx = ((int.tryParse(m.group(2)!) ?? 1) - 1).clamp(0, 30);
    } else {
      final now = DateTime.now();
      _monthIdx = now.month - 1;
      _dayIdx = now.day - 1;
    }
  }

  int get _day => (_dayIdx + 1).clamp(1, _maxDay[_monthIdx]);
  String get _summary => '$_day ${_gen[_monthIdx]}';

  void _commit() {
    final md = '${(_monthIdx + 1).toString().padLeft(2, '0')}-'
        '${_day.toString().padLeft(2, '0')}';
    Navigator.pop(context, md);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 2),
              child: Row(
                children: [
                  const Text('День рождения',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(AppL10n.t('common_cancel')),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 216,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  IgnorePointer(
                    child: Container(
                      height: 40,
                      margin: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      _Wheel(
                        count: 31,
                        loop: true,
                        initialIndex: _dayIdx,
                        width: 88,
                        onChanged: (i) => setState(() => _dayIdx = i),
                        builder: (i) => Text('${i + 1}'),
                      ),
                      Expanded(
                        child: _Wheel(
                          count: 12,
                          loop: true,
                          initialIndex: _monthIdx,
                          onChanged: (i) => setState(() => _monthIdx = i),
                          builder: (i) => Text(
                            _nom[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _commit,
                  child: Text('${AppL10n.t('common_done')} · $_summary'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Scroll physics that keeps spinning on a hard flick — the "крутанул сильно,
/// долго крутится" feel — while leaving gentle drags precise.
class _MomentumWheelPhysics extends FixedExtentScrollPhysics {
  const _MomentumWheelPhysics({super.parent});

  @override
  _MomentumWheelPhysics applyTo(ScrollPhysics? ancestor) =>
      _MomentumWheelPhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    // Amplify only real flings; small nudges stay 1:1 so you can dial a single
    // minute without it running away.
    final v = velocity.abs() > 350 ? velocity * 1.9 : velocity;
    return super.createBallisticSimulation(position, v);
  }

  @override
  SpringDescription get spring => const SpringDescription(
        mass: 0.6,
        stiffness: 90,
        damping: 16,
      );
}

class _WheelSheet extends StatefulWidget {
  final DateTime? initial;
  const _WheelSheet({this.initial});

  @override
  State<_WheelSheet> createState() => _WheelSheetState();
}

class _WheelSheetState extends State<_WheelSheet> {
  static const int _dayCount = 366; // today + next year

  late DateTime _midnightToday;
  late int _dayIndex;
  late int _hour;
  late int _minute;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _midnightToday = DateTime(now.year, now.month, now.day);
    final start = widget.initial ?? now.add(const Duration(minutes: 30));
    final startDay = DateTime(start.year, start.month, start.day);
    _dayIndex = startDay.difference(_midnightToday).inDays.clamp(0, _dayCount - 1);
    _hour = start.hour;
    _minute = start.minute;
  }

  DateTime get _chosen {
    final day = _midnightToday.add(Duration(days: _dayIndex));
    return DateTime(day.year, day.month, day.day, _hour, _minute);
  }

  String _dayLabel(int index) {
    final day = _midnightToday.add(Duration(days: index));
    final code = Localizations.localeOf(context).languageCode;
    if (index == 0) return code == 'en' ? 'Today' : 'Сегодня';
    if (index == 1) return code == 'en' ? 'Tomorrow' : 'Завтра';
    // Locale-aware "Tue, 5 Aug" for the rest.
    return MaterialLocalizations.of(context).formatMediumDate(day);
  }

  void _commit() {
    final when = _chosen;
    if (!when.isAfter(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.t('cs_pick_future_time'))),
      );
      return;
    }
    Navigator.pop(context, when);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 2),
              child: Row(
                children: [
                  Text('Отправить позже',
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(AppL10n.t('common_cancel')),
                  ),
                ],
              ),
            ),
            // ── The drums ──────────────────────────────────────────────
            SizedBox(
              height: 216,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Centre selection band the numbers roll through.
                  IgnorePointer(
                    child: Container(
                      height: 40,
                      margin: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: _Wheel(
                          count: _dayCount,
                          initialIndex: _dayIndex,
                          onChanged: (i) => setState(() => _dayIndex = i),
                          builder: (i) => Text(
                            _dayLabel(i),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      _Wheel(
                        count: 24,
                        loop: true,
                        initialIndex: _hour,
                        width: 64,
                        onChanged: (i) => setState(() => _hour = i),
                        builder: (i) => Text(i.toString().padLeft(2, '0')),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(':',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurfaceVariant)),
                      ),
                      _Wheel(
                        count: 60,
                        loop: true,
                        initialIndex: _minute,
                        width: 64,
                        onChanged: (i) => setState(() => _minute = i),
                        builder: (i) => Text(i.toString().padLeft(2, '0')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _commit,
                  child: Text('${AppL10n.t('common_done')} · '
                      '${_dayLabel(_dayIndex)} '
                      '${_hour.toString().padLeft(2, '0')}:'
                      '${_minute.toString().padLeft(2, '0')}'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One 3D drum column.
class _Wheel extends StatefulWidget {
  final int count;
  final int initialIndex;
  final ValueChanged<int> onChanged;
  final Widget Function(int index) builder;
  final bool loop;
  final double? width;

  const _Wheel({
    required this.count,
    required this.initialIndex,
    required this.onChanged,
    required this.builder,
    this.loop = false,
    this.width,
  });

  @override
  State<_Wheel> createState() => _WheelState();
}

class _WheelState extends State<_Wheel> {
  late final FixedExtentScrollController _ctrl =
      FixedExtentScrollController(initialItem: widget.initialIndex);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final wheel = ListWheelScrollView.useDelegate(
      controller: _ctrl,
      itemExtent: 40,
      physics: const _MomentumWheelPhysics(),
      // The 3D drum: curved, fading toward the rim, magnified at the centre.
      diameterRatio: 1.25,
      perspective: 0.006,
      useMagnifier: true,
      magnification: 1.18,
      overAndUnderCenterOpacity: 0.35,
      onSelectedItemChanged: (raw) {
        final i = widget.loop ? raw % widget.count : raw;
        playTick();
        widget.onChanged(i);
      },
      childDelegate: widget.loop
          ? ListWheelChildLoopingListDelegate(
              children: [
                for (var i = 0; i < widget.count; i++) _cell(cs, i),
              ],
            )
          : ListWheelChildBuilderDelegate(
              childCount: widget.count,
              builder: (_, i) => _cell(cs, i),
            ),
    );
    return SizedBox(width: widget.width, child: wheel);
  }

  Widget _cell(ColorScheme cs, int i) => Center(
        child: DefaultTextStyle(
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          child: widget.builder(i),
        ),
      );
}
