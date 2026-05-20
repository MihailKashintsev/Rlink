import 'dart:html' as html;
import 'dart:typed_data';

String? createWebObjectUrl(List<Uint8List> chunks, String mimeType) {
  if (chunks.isEmpty) return null;
  final blob = html.Blob(chunks, mimeType);
  return html.Url.createObjectUrlFromBlob(blob);
}

Future<Uint8List?> readWebObjectUrlBytes(String url) async {
  if (url.isEmpty) return null;
  final requestUrl = url.split('#').first;
  final request = await html.HttpRequest.request(
    requestUrl,
    responseType: 'arraybuffer',
  );
  final response = request.response;
  if (response is ByteBuffer) return response.asUint8List();
  if (response is Uint8List) return response;
  return null;
}

void revokeWebObjectUrl(String url) {
  if (url.startsWith('blob:')) {
    html.Url.revokeObjectUrl(url.split('#').first);
  }
}
