import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../services/ble_service.dart';
import '../../services/chat_storage_service.dart';

/// A plain-language view of mesh health: who's directly around right now,
/// and which outgoing messages are still waiting to be delivered — the
/// two questions "Живой лог доставки"'s raw TX/RX/DROP trace doesn't
/// answer at a glance.
class MeshStatusScreen extends StatefulWidget {
  const MeshStatusScreen({super.key});

  @override
  State<MeshStatusScreen> createState() => _MeshStatusScreenState();
}

class _MeshStatusScreenState extends State<MeshStatusScreen> {
  final Map<String, String> _nicknameCache = {};
  List<ChatMessage> _undelivered = [];
  bool _loadingUndelivered = true;

  @override
  void initState() {
    super.initState();
    BleService.instance.peersCount.addListener(_onMeshChanged);
    BleService.instance.peerMappingsVersion.addListener(_onMeshChanged);
    BleService.instance.exchangeStates.addListener(_onMeshChanged);
    _refreshUndelivered();
  }

  @override
  void dispose() {
    BleService.instance.peersCount.removeListener(_onMeshChanged);
    BleService.instance.peerMappingsVersion.removeListener(_onMeshChanged);
    BleService.instance.exchangeStates.removeListener(_onMeshChanged);
    super.dispose();
  }

  void _onMeshChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshUndelivered() async {
    if (!mounted) return;
    setState(() => _loadingUndelivered = true);
    final list =
        await ChatStorageService.instance.getUndeliveredOutgoingMessages();
    if (!mounted) return;
    setState(() {
      _undelivered = list;
      _loadingUndelivered = false;
    });
  }

  Future<String> _nicknameFor(String peerId) async {
    final cached = _nicknameCache[peerId];
    if (cached != null) return cached;
    final contact = await ChatStorageService.instance.getContact(peerId);
    final name = (contact != null && contact.nickname.isNotEmpty)
        ? contact.nickname
        : '${peerId.substring(0, peerId.length.clamp(0, 8))}…';
    _nicknameCache[peerId] = name;
    return name;
  }

  static String _exchangeLabel(int? state) {
    switch (state) {
      case 0:
        return 'подключение';
      case 1:
        return 'профиль отправлен';
      case 2:
        return 'профиль получен';
      case 3:
        return 'готово';
      default:
        return 'неизвестно';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final peers = BleService.instance.connectedPeerIds;
    final exchangeStates = BleService.instance.exchangeStates.value;

    final undeliveredByPeer = <String, int>{};
    for (final m in _undelivered) {
      undeliveredByPeer[m.peerId] = (undeliveredByPeer[m.peerId] ?? 0) + 1;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Статус mesh'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
            onPressed: _refreshUndelivered,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshUndelivered,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text('Рядом по Bluetooth (${peers.length})',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (peers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('Никого не видно поблизости',
                    style: TextStyle(color: cs.onSurfaceVariant)),
              )
            else
              ...peers.map((peerId) => FutureBuilder<String>(
                    future: _nicknameFor(peerId),
                    builder: (_, snap) {
                      final name = snap.data ??
                          '${peerId.substring(0, peerId.length.clamp(0, 8))}…';
                      final rssi = BleService.instance.getRssi(peerId);
                      final pending = undeliveredByPeer[peerId] ?? 0;
                      return ListTile(
                        leading: Icon(Icons.bluetooth_connected,
                            color: cs.primary),
                        title: Text(name),
                        subtitle: Text(
                          [
                            if (rssi != null) 'сигнал ${rssi}dBm',
                            _exchangeLabel(exchangeStates[peerId]),
                            if (pending > 0) '$pending не доставлено',
                          ].join(' · '),
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant),
                        ),
                      );
                    },
                  )),
            const SizedBox(height: 20),
            Text('Ожидают доставки (${undeliveredByPeer.length})',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (_loadingUndelivered)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (undeliveredByPeer.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('Все сообщения доставлены',
                    style: TextStyle(color: cs.onSurfaceVariant)),
              )
            else
              ...undeliveredByPeer.entries.map((e) {
                final directlyReachable = peers.contains(e.key);
                return FutureBuilder<String>(
                  future: _nicknameFor(e.key),
                  builder: (_, snap) {
                    final name = snap.data ??
                        '${e.key.substring(0, e.key.length.clamp(0, 8))}…';
                    return ListTile(
                      leading: Icon(
                        Icons.schedule_send_outlined,
                        color: directlyReachable
                            ? Colors.amber
                            : cs.onSurfaceVariant,
                      ),
                      title: Text(name),
                      subtitle: Text(
                        directlyReachable
                            ? 'рядом — отправляется'
                            : 'ждём relay или путь через mesh',
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                      trailing: Text('${e.value}'),
                    );
                  },
                );
              }),
          ],
        ),
      ),
    );
  }
}
