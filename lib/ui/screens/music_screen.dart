import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/audio_queue_mini_player_layout.dart';
import '../../services/music_catalog_service.dart';
import '../../services/music_library_service.dart';
import '../../services/google_drive_channel_backup.dart';
import '../../services/my_tracks_service.dart';
import '../../services/voice_service.dart';
import 'package:flutter/services.dart';

import '../widgets/music_lyrics_panel.dart';
import '../widgets/track_upload_sheet.dart';
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
  late final TabController _tabs = TabController(length: 4, vsync: this);
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<CatalogTrack> _results = const [];
  bool _loading = false;
  bool _searched = false;

  // "Линия" — endless random stream. Playback uses VoiceService's queue, so
  // one track rolls into the next without us scheduling anything.
  bool _signingIn = false;
  String? _signInError;

  final List<CatalogTrack> _line = [];
  bool _lineLoading = false;
  int _linePage = 0;

  @override
  void initState() {
    super.initState();
    MusicLibraryService.instance.load();
    MyTracksService.instance.load();
    _loadMoreLine();
    // This screen has its own player bar — the floating one would be a second
    // player for the same track.
    AudioQueueMiniPlayerLayout.instance.pushSuppression();
  }

  Future<void> _loadMoreLine() async {
    if (_lineLoading) return;
    setState(() => _lineLoading = true);
    final raw = await MusicCatalogService.instance.randomStream(
      page: _linePage,
    );
    // Drop tracks whose content node can't be reached from here, so Линия
    // never offers something that silently won't play.
    final more = await filterReachable(raw);
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
    // Uploaded tracks are part of the same library — match them first.
    final q = v.trim().toLowerCase();
    final mine = MyTracksService.instance.tracks.value
        .where((t) =>
            t.title.toLowerCase().contains(q) ||
            t.artist.toLowerCase().contains(q))
        .map((t) => t.toCatalogTrack());
    setState(() {
      _results = [...mine, ...r];
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
            Tab(text: 'Мои'),
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
                    _myTab(cs),
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

  Widget _myTab(ColorScheme cs) {
    // Uploading puts the file on the user's OWN Drive, so a linked Google
    // account is a hard requirement — gate the whole tab rather than letting
    // them fill the form and fail at the last step.
    if (!isGoogleLinked) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 44, color: cs.onSurfaceVariant),
              const SizedBox(height: 12),
              const Text('Нужен вход в Google',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                'Треки загружаются на ваш собственный Google Drive — Rlink '
                'хранит только ссылку. Без привязанного аккаунта загружать '
                'некуда.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _signingIn ? null : _linkGoogle,
                icon: _signingIn
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.login),
                label: Text(_signingIn ? 'Входим…' : 'Войти в Google'),
              ),
              if (_signInError != null) ...[
                const SizedBox(height: 10),
                Text(_signInError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: cs.error)),
              ],
              const SizedBox(height: 8),
              Text(
                'Привязать также можно в Настройки → Google Drive.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    return ValueListenableBuilder<List<MyTrack>>(
      valueListenable: MyTracksService.instance.tracks,
      builder: (_, mine, __) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Row(
                children: [
                  Icon(Icons.cloud_done_outlined, size: 16, color: cs.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      googleAccountEmail ?? 'Google подключён',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: FilledButton.icon(
                onPressed: () async {
                  final ref = await showTrackUploadSheet(context);
                  if (ref == null || !context.mounted) return;
                  await Clipboard.setData(
                      ClipboardData(text: parseMusicRef(ref).url));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                          'Загружено. Ссылка скопирована — её можно вставить в профиль.'),
                    ),
                  );
                },
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('Загрузить трек на Google Drive'),
              ),
            ),
            Expanded(
              child: mine.isEmpty
                  ? _hint(cs,
                      'Здесь будут ваши треки.\nФайл лежит на вашем Google Drive — Rlink хранит только ссылку.')
                  : ListView.builder(
                      itemCount: mine.length,
                      itemBuilder: (_, i) {
                        final t = mine[i];
                        return MyTrackRow(
                          track: t,
                          onPlay: () {
                            final ref = encodeMusicRef(t.toCatalogTrack());
                            rememberTrackRef(ref);
                            VoiceService.instance.play(t.url, title: t.title);
                          },
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _linkGoogle() async {
    setState(() {
      _signingIn = true;
      _signInError = null;
    });
    try {
      await GoogleDriveChannelBackup.ensureUserSignedIn(interactive: true);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _signingIn = false;
      if (!isGoogleLinked) {
        _signInError = GoogleDriveChannelBackup.lastSignInError ??
            'Не удалось войти. На iPhone используйте «Привязать через Safari» '
                'в Настройки → Google Drive.';
      }
    });
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
          subtitle: Row(
            children: [
              Flexible(
                child: Text(t.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12)),
              ),
              if (t.isPreview) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('30 сек',
                      style: TextStyle(
                          fontSize: 9, color: cs.onSecondaryContainer)),
                ),
              ],
            ],
          ),
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
          onTap: () async {
            rememberTrackRef(ref);
            if (onTap != null) {
              onTap();
              return;
            }
            final url = await resolvePlayableUrl(t.url);
            if (url == null) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Трек недоступен')),
              );
              return;
            }
            VoiceService.instance.play(url, title: t.title);
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
