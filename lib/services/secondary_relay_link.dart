import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'gossip_router.dart';

/// A second, minimal connection to ONE extra relay — the simplest possible
/// version of "reach people on a different relay than mine": the client
/// itself just also plugs into that other server, the same way it already
/// plugs into two Bluetooth peers at once. No new server-to-server protocol,
/// no per-contact bookkeeping — this link doesn't know or care WHO it might
/// reach, it just registers under the same identity and lets the existing
/// server-side "deliver to whoever's connected under this key" routing do
/// the rest.
///
/// Deliberately NOT a second [RelayService]: no presence, no bot/channel
/// directory, no premium/mailbox snapshot, no chunked-media draining — those
/// stay exclusively on the primary connection. This link only relays the
/// packet types a real conversation needs (message, ack, edit/delete/react,
/// typing, pairing, call signaling, pin), matching [GossipRouter]'s own
/// `directedTypes` set in `packet_transport.dart`.
class SecondaryRelayLink {
  SecondaryRelayLink({
    required this.url,
    required this.myPublicKey,
    required this.myNick,
    required this.myX25519,
  });

  final String url;
  final String Function() myPublicKey;
  final String Function() myNick;
  final String Function() myX25519;

  static const _relevantTypes = <String>{
    'msg',
    'raw',
    'pair_req',
    'pair_acc',
    'typing',
    'ack',
    'edit',
    'delete',
    'react',
    'dm_pin',
    'call_sig',
  };

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _registered = false;
  int _retryCount = 0;

  bool get isReady => _registered;

  Future<void> connect() async {
    if (_disposed || _channel != null) return;
    final key = myPublicKey();
    if (key.isEmpty) return;
    try {
      final ws = WebSocketChannel.connect(Uri.parse(url));
      await ws.ready;
      _channel = ws;
      _sub = ws.stream
          .listen(_onMessage, onDone: _onClosed, onError: (_) => _onClosed());
      ws.sink.add(jsonEncode({
        'type': 'register',
        'publicKey': key,
        'nick': myNick(),
        if (myX25519().isNotEmpty) 'x25519': myX25519(),
      }));
    } catch (e) {
      debugPrint('[RLINK][Relay2] connect failed ($url): $e');
      _channel = null;
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'registered':
        _registered = true;
        _retryCount = 0;
        debugPrint('[RLINK][Relay2] registered on $url');
        break;
      case 'error':
        debugPrint('[RLINK][Relay2] server error: ${msg['msg']}');
        break;
      case 'packet':
        _onIncomingPacket(msg);
        break;
      default:
        // presence/bot-dir/premium/etc. — not this link's job.
        break;
    }
  }

  void _onIncomingPacket(Map<String, dynamic> msg) {
    final from = msg['from'] as String?;
    final data = msg['data'] as String?;
    if (from == null || data == null) return;
    try {
      final bytes = base64Decode(data);
      GossipRouter.instance.onPacketReceived(Uint8List.fromList(bytes),
          sourceId: 'relay2:$from');
    } catch (e) {
      debugPrint('[RLINK][Relay2] bad packet from $from: $e');
    }
    final relayMsgId = msg['relayMsgId'] as String?;
    if (relayMsgId != null && relayMsgId.isNotEmpty) {
      _send({'type': 'relay_ack', 'msgId': relayMsgId});
    }
  }

  /// Sends [packet] over this link if it's a type worth reaching a second
  /// relay for and the link is actually registered — a message queued
  /// while this link is still connecting is simply not this link's
  /// delivery to make; the primary connection (or a later retry via
  /// [OutboxService]) still covers it.
  Future<void> send(GossipPacket packet, {String? recipientKey}) async {
    if (!_registered || !_relevantTypes.contains(packet.type)) return;
    final b64 = base64Encode(packet.encode());
    final envelope = (recipientKey != null && recipientKey.isNotEmpty)
        ? {
            'type': 'packet',
            'to': recipientKey,
            'msgId': packet.id,
            'data': b64
          }
        : {'type': 'broadcast', 'data': b64};
    _send(envelope);
  }

  void _send(Map<String, dynamic> payload) {
    try {
      _channel?.sink.add(jsonEncode(payload));
    } catch (_) {}
  }

  void _onClosed() {
    _sub?.cancel();
    _sub = null;
    _channel = null;
    _registered = false;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    final delay = _retryCount >= 5 ? 30 : (1 << _retryCount);
    _retryCount++;
    _reconnectTimer = Timer(Duration(seconds: delay), connect);
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _registered = false;
  }
}
