import 'dart:async';

import 'ble_service.dart';
import 'gossip_router.dart' show GossipPacket;
import 'mesh_forwarder.dart';
import 'wifi_direct_service.dart';

const _mediaPacketTypes = <String>{'img_chunk', 'img_meta', 'blob'};

class _IoMeshForwarder implements MeshForwarder {
  @override
  Future<void> forward(GossipPacket packet, int mode) async {
    final wifiDirectReady = mode == 2 &&
        WifiDirectService.instance.isRunning &&
        WifiDirectService.instance.peersCount.value > 0;
    if (wifiDirectReady) {
      unawaited(WifiDirectService.instance.sendToAll(packet.encode()));
    }
    // Media chunks are the one thing worth routing deliberately rather than
    // just flooding everywhere: BLE's ~180-byte writes make a photo/video
    // trickle out over many round-trips, while Wi-Fi Direct carries the
    // exact same chunk in one shot. Sending it over BOTH wastes BLE's
    // scarce bandwidth on a duplicate that Wi-Fi Direct was already going
    // to deliver — bandwidth other, unrelated chats on the mesh are also
    // competing for. Skip BLE for media specifically once Wi-Fi Direct has
    // someone to carry it to; fall back to BLE if it doesn't (e.g. no Wi-Fi
    // Direct peer, or not running at all) so delivery never regresses.
    final skipBleForMedia = wifiDirectReady && _mediaPacketTypes.contains(packet.type);
    if (mode != 1 && !skipBleForMedia) {
      await BleService.instance.broadcastPacket(packet);
    }
  }
}

MeshForwarder createMeshForwarder() => _IoMeshForwarder();
