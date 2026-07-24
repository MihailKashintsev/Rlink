import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/audio_queue_mini_player_layout.dart';
import '../../services/music_catalog_service.dart';
import '../../services/music_library_service.dart';
import '../../services/voice_service.dart';
import '../widgets/music_lyrics_panel.dart';
import 'music_player_screen.dart';

/// Built-in music player: catalog search, a local "liked" list and a player
/// bar. Playback runs through VoiceService, so leaving this screen hands the
/// track to the global mini player exactly like a voice message.
class MusicScreen extends StatefulWidget {
  const MusicScreen({super.key});

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<CatalogTrack> _results = const [];
  bool _loading = false;
  bool _searched = false;

  // "Линия" — endless random stream. Playback uses VoiceService's queue, so
  // one track rolls into the next without us scheduling anything.
  final List<CatalogTrack> _line = [];
  bool _lineLoading = false;
  int _linePage = 0;

  @override
  void initState() {
    super.initState();
    MusicLibraryService.instance.load();
    _loadMoreLine();
    // This screen has its own player bar — the floating one would be a second
    // player for the same track.
    AudioQueueMiniPlayerLayout.instance.pushSuppression();
  }

  Future<void> _loadMoreLine() async {
    if (_lineLoading) return;
    setState(() => _lineLoading = true);
    final more = await MusicCatalogService.instance.randomStream(
      page: _linePage,
    );
    if (!mounted) return;
    setState(() {
      _linePage++;
      final seen = _line.map((t) => t.streamUrl).toSet();
      _line.addAll(more.where((t) => !seen.contains(t.streamUrl)));
      _lineLoading = false;
    });
  }

  void _playLineFrom(int index) {
    for (final t in _line) {
      rememberTrackRef(encodeMusicRef(t));
    }
    VoiceService.instance.playQueue([
      for (final t in _line.skip(index))
        PlaybackQueueItem(
          path: t.streamUrl,
          title: t.title,
          kind: PlaybackMediaKind.audioFile,
        ),
    ]);
  }

  @override
  void dispose() {
    AudioQueueMiniPlayerLayout.instance.popSuppression();
    _debounce?.cancel();
    _searchCtrl.dispose();
    _tabs.dispose();
    super.dispose();
  }

  void _onQuery(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _run(v));
  }

  Future<void> _run(String v) async {
    if (v.trim().length < 2) {
      setState(() {
        _results = const [];
        _searched = false;
      });
      return;
    }
    setState(() => _loading = true);
    final r = await MusicCatalogService.instance.search(v);
    if (!mounted) return;
    setState(() {
      _results = r;
      _loading = false;
      _searched = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Музыка'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Линия'),
            Tab(text: 'Поиск'),
            Tab(text: 'Нравится'),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          // Desktop: rows stretched edge-to-edge across a 1280px window and
          // read terribly. Cap the column like every desktop music app does.
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            children: [
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    _lineTab(cs),
                    _searchTab(cs),
                    _likedTab(cs),
                  ],
                ),
              ),
              const _PlayerBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _lineTab(ColorScheme cs) {
    if (_line.isEmpty) {
      return _lineLoading
          ? const Center(child: CircularProgressIndicator())
          : _hint(cs, 'Не удалось получить поток — проверьте интернет');
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        // Endless: top up before the user reaches the bottom.
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 600) {
          _loadMoreLine();
        }
        return false;
      },
      child: ListView.builder(
        itemCount: _line.length + 1,
        itemBuilder: (_, i) {
          if (i == _line.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return _trackRow(cs, encodeMusicRef(_line[i]), onTap: () {
            _playLineFrom(i);
          });
        },
      ),
    );
  }

  Widget _searchTab(ColorScheme cs) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: TextField(
            controller: _searchCtrl,
            onChanged: _onQuery,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: 'Поиск в каталоге',
              filled: true,
              fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _results.isEmpty
                  ? _hint(
                      cs,
                      _searched
                          ? 'Ничего не нашлось'
                          : 'Найдите трек по названию или исполнителю')
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (_, i) =>
                          _trackRow(cs, encodeMusicRef(_results[i])),
                    ),
        ),
      ],
    );
  }

  Widget _likedTab(ColorScheme cs) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: MusicLibraryService.instance.liked,
      builder: (_, refs, __) {
        if (refs.isEmpty) {
          return _hint(cs, 'Пока пусто — жми ♥ у трека в поиске');
        }
        return ListView.builder(
          itemCount: refs.length,
          itemBuilder: (_, i) => _trackRow(cs, refs[i]),
        );
      },
    );
  }

  Widget _hint(ColorScheme cs, String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant)),
        ),
      );

  Widget _trackRow(ColorScheme cs, String ref, {VoidCallback? onTap}) {
    final t = parseMusicRef(ref);
    return ValueListenableBuilder<VoicePlaybackSession?>(
      valueListenable: VoiceService.instance.playbackSession,
      builder: (_, session, __) {
        final isCurrent = session?.path == t.url;
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: t.artwork != null
                ? Image.network(t.artwork!,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _art(cs))
                : _art(cs),
          ),
          title: Text(t.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                  color: isCurrent ? cs.primary : null)),
          subtitle: Text(t.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
          trailing: ValueListenableBuilder<List<String>>(
            valueListenable: MusicLibraryService.instance.liked,
            builder: (_, __, ___) {
              final liked = MusicLibraryService.instance.isLiked(ref);
              return IconButton(
                icon: Icon(
                  liked ? Icons.favorite : Icons.favorite_border,
                  color: liked ? const Color(0xFFFF4D6D) : cs.onSurfaceVariant,
                ),
                onPressed: () => MusicLibraryService.instance.toggle(ref),
              );
            },
          ),
          onTap: () {
            rememberTrackRef(ref);
            if (onTap != null) {
              onTap();
            } else {
              VoiceService.instance.play(t.url, title: t.title);
            }
          },
        );
      },
    );
  }

  Widget _art(ColorScheme cs) => Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [cs.primary, cs.tertiary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: const Icon(Icons.album_rounded, color: Colors.white, size: 22),
      );
}

/// Bottom player: artwork that breathes while playing, a seekable slider and
/// the live-transcription (beta) toggle.
class _PlayerBar extends StatelessWidget {
  const _PlayerBar();

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final voice = VoiceService.instance;

    return ValueListenableBuilder<VoicePlaybackSession?>(
      valueListenable: voice.playbackSession,
      builder: (context, session, _) {
        if (session == null) return const SizedBox.shrink();
        final isPaused = session.isPaused;

        return Material(
          elevation: 8,
          color: cs.surfaceContainerHigh,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      // Breathing artwork — a quiet "it's playing" cue that
                      // costs one implicit animation, no controller.
                      TweenAnimationBuilder<double>(
                        key: ValueKey(isPaused),
                        tween: Tween(begin: isPaused ? 1.0 : 0.94, end: 1.0),
                        duration: const Duration(milliseconds: 900),
                        curve: Curves.easeOutBack,
                        builder: (_, scale, child) =>
                            Transform.scale(scale: scale, child: child),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            gradient: LinearGradient(
                              colors: [cs.primary, cs.tertiary],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: const Icon(Icons.music_note_rounded,
                              color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const MusicPlayerScreen())),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  session.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                              Icon(Icons.expand_less,
                                  size: 18, color: cs.onSurfaceVariant),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        iconSize: 34,
                        color: cs.primary,
                        icon: Icon(isPaused
                            ? Icons.play_circle_fill
                            : Icons.pause_circle_filled),
                        onPressed: () => isPaused
                            ? voice.resumePlayback()
                            : voice.pausePlayback(),
                      ),
                    ],
                  ),
                  ValueListenableBuilder<double>(
                    valueListenable: voice.playProgress,
                    builder: (_, progress, __) =>
                        ValueListenableBuilder<Duration>(
                      valueListenable: voice.playDuration,
                      builder: (_, dur, ___) {
                        final pos = dur * progress.clamp(0.0, 1.0);
                        return Row(
                          children: [
                            Text(_fmt(pos),
                                style: const TextStyle(fontSize: 11)),
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 6),
                                  overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 14),
                                ),
                                child: Slider(
                                  value: progress.clamp(0.0, 1.0),
                                  onChanged: (v) => voice.seekTo(v),
                                ),
                              ),
                            ),
                            Text(_fmt(dur),
                                style: const TextStyle(fontSize: 11)),
                          ],
                        );
                      },
                    ),
                  ),
                  MusicLyricsPanel(
                    url: session.path,
                    title: session.title,
                    artist:
                        parseMusicRef(trackRefFor(session.path) ?? '').artist,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
