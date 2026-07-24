import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../../services/my_tracks_service.dart';

/// Upload a track to the user's own Google Drive: pick the audio, set cover,
/// title and artist, get a link back that can go into a profile or be shared.
Future<String?> showTrackUploadSheet(BuildContext context) {
  // Second gate: the sheet is also reachable from elsewhere, and an upload
  // without a linked account can only end in an error at the last step.
  if (!isGoogleLinked) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Сначала войдите в Google — Настройки → Google Drive'),
      ),
    );
    return Future<String?>.value();
  }
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _TrackUploadSheet(),
  );
}

class _TrackUploadSheet extends StatefulWidget {
  const _TrackUploadSheet();

  @override
  State<_TrackUploadSheet> createState() => _TrackUploadSheetState();
}

class _TrackUploadSheetState extends State<_TrackUploadSheet> {
  final _title = TextEditingController();
  final _artist = TextEditingController();
  Uint8List? _audio;
  String _audioName = '';
  String? _coverDataUrl;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  Future<void> _pickAudio() async {
    final r = await FilePicker.platform
        .pickFiles(type: FileType.audio, withData: true);
    final f = r?.files.single;
    if (f?.bytes == null) return;
    setState(() {
      _audio = f!.bytes;
      _audioName = f.name;
      if (_title.text.trim().isEmpty) {
        final dot = f.name.lastIndexOf('.');
        _title.text = dot > 0 ? f.name.substring(0, dot) : f.name;
      }
    });
  }

  Future<void> _pickCover() async {
    final r = await FilePicker.platform
        .pickFiles(type: FileType.image, withData: true);
    final bytes = r?.files.single.bytes;
    if (bytes == null) return;
    // Shrink hard: the cover rides inside the track link, so it must stay tiny.
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return;
    final small = img.copyResize(decoded, width: 160);
    final jpg = img.encodeJpg(small, quality: 70);
    setState(() =>
        _coverDataUrl = 'data:image/jpeg;base64,${base64Encode(jpg)}');
  }

  Future<void> _upload() async {
    if (_audio == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ref = await MyTracksService.instance.upload(
      fileName: _audioName,
      bytes: _audio!,
      title: _title.text,
      artist: _artist.text,
      artworkDataUrl: _coverDataUrl,
    );
    if (!mounted) return;
    if (ref == null) {
      setState(() {
        _busy = false;
        _error = MyTracksService.instance.lastError ?? 'Не удалось загрузить';
      });
      return;
    }
    Navigator.pop(context, ref);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text('Загрузить трек',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              'Файл ляжет на ваш Google Drive. Rlink хранит только ссылку — '
              'остальные слушают прямо оттуда, ничего не скачивая.',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: _busy ? null : _pickCover,
                  child: Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _coverDataUrl != null
                        ? Image.network(_coverDataUrl!, fit: BoxFit.cover)
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.image_outlined,
                                  color: cs.onSurfaceVariant),
                              const SizedBox(height: 2),
                              Text('Обложка',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: cs.onSurfaceVariant)),
                            ],
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    children: [
                      TextField(
                        controller: _title,
                        enabled: !_busy,
                        decoration: const InputDecoration(
                          labelText: 'Название',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _artist,
                        enabled: !_busy,
                        decoration: const InputDecoration(
                          labelText: 'Исполнитель',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickAudio,
              icon: const Icon(Icons.audio_file_outlined),
              label: Text(
                _audio == null
                    ? 'Выбрать аудиофайл'
                    : '$_audioName · ${(_audio!.length / 1048576).toStringAsFixed(1)} МБ',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: TextStyle(fontSize: 12, color: cs.error)),
            ],
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: (_audio == null || _busy) ? null : _upload,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_upload_outlined),
              label: Text(_busy ? 'Загружаем…' : 'Загрузить на Google Drive'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Row for an already-uploaded track: play, copy link, remove.
class MyTrackRow extends StatelessWidget {
  final MyTrack track;
  final VoidCallback onPlay;
  const MyTrackRow({super.key, required this.track, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: track.artwork != null
            ? Image.network(track.artwork!,
                width: 44, height: 44, fit: BoxFit.cover)
            : Container(
                width: 44,
                height: 44,
                color: cs.surfaceContainerHighest,
                child: Icon(Icons.music_note, color: cs.onSurfaceVariant),
              ),
      ),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        track.artist.isEmpty ? 'Мой трек · Google Drive' : track.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      onTap: onPlay,
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          if (v == 'copy') {
            await Clipboard.setData(ClipboardData(text: track.url));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Ссылка скопирована')),
              );
            }
          }
          if (v == 'remove') {
            await MyTracksService.instance.remove(track.url);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'copy', child: Text('Скопировать ссылку')),
          PopupMenuItem(value: 'remove', child: Text('Убрать из списка')),
        ],
      ),
    );
  }
}
