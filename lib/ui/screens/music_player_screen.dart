import 'package:flutter/material.dart';

import '../../services/audio_queue_mini_player_layout.dart';
import '../../services/music_catalog_service.dart';
import '../../services/music_library_service.dart';
import '../../services/voice_service.dart';
import '../widgets/music_lyrics_panel.dart';

/// Full-screen "now playing", opened from either mini player.
///
/// It renders whatever VoiceService is currently on, so it also works for a
/// track started somewhere else (profile card, Линия) — metadata comes from
/// the ref cache, with a graceful fallback to the bare session title.
class MusicPlayerScreen extends StatefulWidget {
  const MusicPlayerScreen({super.key});

  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}

class _MusicPlayerScreenState extends State<MusicPlayerScreen> {
  @override
  void initState() {
    super.initState();
    // Hide the floating bar while the full player owns the screen.
    AudioQueueMiniPlayerLayout.instance.pushSuppression();
  }

  @override
  void dispose() {
    AudioQueueMiniPlayerLayout.instance.popSuppression();
    super.dispose();
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final voice = VoiceService.instance;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.expand_more),
          tooltip: 'Свернуть',
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Сейчас играет'),
      ),
      body: ValueListenableBuilder<VoicePlaybackSession?>(
        valueListenable: voice.playbackSession,
        builder: (context, session, _) {
          if (session == null) {
            return Center(
              child: Text('Ничего не играет',
                  style: TextStyle(color: cs.onSurfaceVariant)),
            );
          }
          final cachedRef = trackRefFor(session.path);
          final ref = cachedRef != null ? parseMusicRef(cachedRef) : null;
          final title =
              ref?.title.isNotEmpty == true ? ref!.title : session.title;
          final artist = ref?.artist ?? '';
          final isPaused = session.isPaused;

          return SafeArea(
            child: LayoutBuilder(
              builder: (context, box) {
                final wide = box.maxWidth >= 820;
                // Cover is capped so the controls always fit — it used to take
                // the whole screen and push everything below the fold.
                final coverSide = wide
                    ? (box.maxHeight * 0.62).clamp(200.0, 380.0).toDouble()
                    : (box.maxHeight * 0.38)
                        .clamp(120.0, box.maxWidth - 48)
                        .toDouble();

                final cover = TweenAnimationBuilder<double>(
                  key: ValueKey('$isPaused${session.path}'),
                  tween: Tween(begin: isPaused ? 1.0 : 0.92, end: 1.0),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeOutBack,
                  builder: (_, scale, child) =>
                      Transform.scale(scale: scale, child: child),
                  child: SizedBox(
                    width: coverSide,
                    height: coverSide,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: ref?.artwork != null
                          ? Image.network(
                              ref!.artwork!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => _cover(cs),
                            )
                          : _cover(cs),
                    ),
                  ),
                );

                final details = Column(
                  crossAxisAlignment: wide
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      textAlign: wide ? TextAlign.left : TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: wide ? 26 : 20,
                          fontWeight: FontWeight.w700),
                    ),
                    if (artist.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14, color: cs.onSurfaceVariant)),
                    ],
                    if (session.total > 1) ...[
                      const SizedBox(height: 4),
                      Text('${session.indexOneBased} из ${session.total}',
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant)),
                    ],
                    const SizedBox(height: 12),
                    ValueListenableBuilder<double>(
                      valueListenable: voice.playProgress,
                      builder: (_, progress, __) =>
                          ValueListenableBuilder<Duration>(
                        valueListenable: voice.playDuration,
                        builder: (_, dur, ___) {
                          final pos = dur * progress.clamp(0.0, 1.0);
                          return Column(
                            children: [
                              SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 4,
                                  thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 7),
                                ),
                                child: Slider(
                                  value: progress.clamp(0.0, 1.0),
                                  onChanged: voice.seekTo,
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(_fmt(pos),
                                        style: const TextStyle(fontSize: 12)),
                                    Text(_fmt(dur),
                                        style: const TextStyle(fontSize: 12)),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    Row(
                      mainAxisAlignment: wide
                          ? MainAxisAlignment.start
                          : MainAxisAlignment.center,
                      children: [
                        IconButton(
                          iconSize: 32,
                          tooltip: 'Предыдущий трек',
                          icon: const Icon(Icons.skip_previous_rounded),
                          onPressed: voice.playPrevInQueue,
                        ),
                        IconButton(
                          iconSize: 28,
                          tooltip: 'Назад на 15 секунд',
                          icon: const Icon(Icons.replay_10),
                          onPressed: () => _nudge(voice, -15000),
                        ),
                        IconButton(
                          iconSize: 62,
                          color: cs.primary,
                          icon: Icon(isPaused
                              ? Icons.play_circle_fill
                              : Icons.pause_circle_filled),
                          onPressed: () => isPaused
                              ? voice.resumePlayback()
                              : voice.pausePlayback(),
                        ),
                        IconButton(
                          iconSize: 28,
                          tooltip: 'Вперёд на 15 секунд',
                          icon: const Icon(Icons.forward_10),
                          onPressed: () => _nudge(voice, 15000),
                        ),
                        IconButton(
                          iconSize: 32,
                          tooltip: 'Следующий трек',
                          icon: const Icon(Icons.skip_next_rounded),
                          onPressed: voice.hasNextInQueue
                              ? voice.playNextInQueue
                              : null,
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: wide
                          ? MainAxisAlignment.start
                          : MainAxisAlignment.spaceEvenly,
                      children: [
                        ValueListenableBuilder<bool>(
                          valueListenable: voice.repeatOne,
                          builder: (_, on, __) => IconButton(
                            tooltip: 'Повтор трека',
                            icon: Icon(
                              on
                                  ? Icons.repeat_one_rounded
                                  : Icons.repeat_rounded,
                              color: on ? cs.primary : cs.onSurfaceVariant,
                            ),
                            onPressed: () =>
                                voice.repeatOne.value = !voice.repeatOne.value,
                          ),
                        ),
                        if (cachedRef != null)
                          ValueListenableBuilder<List<String>>(
                            valueListenable: MusicLibraryService.instance.liked,
                            builder: (_, __, ___) {
                              final liked = MusicLibraryService.instance
                                  .isLiked(cachedRef);
                              return IconButton(
                                tooltip: 'Нравится',
                                icon: Icon(
                                  liked
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  color: liked
                                      ? const Color(0xFFFF4D6D)
                                      : cs.onSurfaceVariant,
                                ),
                                onPressed: () => MusicLibraryService.instance
                                    .toggle(cachedRef),
                              );
                            },
                          ),
                        _LyricsToggle(
                            url: session.path, title: title, artist: artist),
                      ],
                    ),
                  ],
                );

                if (wide) {
                  // Desktop: cover left, everything else right — a portrait
                  // column wastes most of a 1280px window.
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1000),
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            cover,
                            const SizedBox(width: 40),
                            Expanded(child: details),
                          ],
                        ),
                      ),
                    ),
                  );
                }

                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                  child: Column(
                    children: [
                      cover,
                      const SizedBox(height: 20),
                      details,
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  void _nudge(VoiceService voice, int deltaMs) {
    final dur = voice.playDuration.value.inMilliseconds;
    if (dur <= 0) return;
    final now = voice.playProgress.value * dur;
    voice.seekTo(((now + deltaMs) / dur).clamp(0.0, 1.0));
  }

  Widget _cover(ColorScheme cs) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [cs.primary, cs.tertiary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: const Center(
          child: Icon(Icons.music_note_rounded, color: Colors.white, size: 72),
        ),
      );
}

/// Lyrics opens in a sheet here — inline it would push the transport controls
/// off screen again, which is exactly the complaint this layout fixes.
class _LyricsToggle extends StatelessWidget {
  final String url;
  final String title;
  final String artist;
  const _LyricsToggle(
      {required this.url, required this.title, this.artist = ''});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Текст (бета)',
      icon: const Icon(Icons.lyrics_outlined),
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            height: 320,
            child: SingleChildScrollView(
              child: MusicLyricsPanel(url: url, title: title, artist: artist),
            ),
          ),
        ),
      ),
    );
  }
}
