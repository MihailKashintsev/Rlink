/// STUN/TURN config shared by [CallService] (1:1) and [GroupCallService]
/// (mesh) — one source of truth for TURN credentials instead of two copies
/// that could silently drift apart.
library;

const turnHost = String.fromEnvironment('TURN_HOST', defaultValue: '');
const turnUser = String.fromEnvironment('TURN_USER', defaultValue: '');
const turnPassword =
    String.fromEnvironment('TURN_PASSWORD', defaultValue: '');

Map<String, dynamic> webrtcIceConfig() {
  final servers = <Map<String, dynamic>>[
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    {'urls': 'stun:stun.cloudflare.com:3478'},
    {'urls': 'stun:stun.nextcloud.com:443'},
  ];
  final host = turnHost.trim();
  final user = turnUser.trim();
  final pass = turnPassword.trim();
  if (host.isNotEmpty && user.isNotEmpty && pass.isNotEmpty) {
    servers.add(<String, dynamic>{
      'urls': <String>[
        'turn:$host:3478?transport=udp',
        'turn:$host:3478?transport=tcp',
      ],
      'username': user,
      'credential': pass,
    });
  }
  return <String, dynamic>{
    'iceServers': servers,
    'iceCandidatePoolSize': 4,
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
    'sdpSemantics': 'unified-plan',
  };
}
