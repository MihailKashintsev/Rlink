import 'dart:html' as html;
import 'dart:typed_data';

String? createWebObjectUrl(List<Uint8List> chunks, String mimeType) {
  if (chunks.isEmpty) return null;
  final blob = html.Blob(chunks, mimeType);
  return html.Url.createObjectUrlFromBlob(blob);
}
