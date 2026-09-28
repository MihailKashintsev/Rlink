import Foundation
import CallKit
import Flutter
import WebRTC

/// Reports Rlink calls to iOS's native CallKit so an incoming call gets the
/// real system ring screen (lock-screen UI, system ringtone, swipe-to-answer)
/// instead of a generic local notification. Requires no push entitlement —
/// it only reports calls while the Flutter engine (and thus the WebSocket
/// signaling connection) is alive, i.e. foreground or backgrounded-but-not-
/// killed. Waking a fully-terminated app needs PushKit VoIP push, which
/// needs a paid Apple Developer account; out of scope here.
final class CallKitManager: NSObject, CXProviderDelegate {
    static let shared = CallKitManager()

    private let provider: CXProvider
    private var channel: FlutterMethodChannel?
    private var currentCallId: UUID?

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func attach(channel: FlutterMethodChannel) {
        self.channel = channel
    }

    func reportIncomingCall(callId: String, handle: String, hasVideo: Bool) {
        guard let uuid = UUID(uuidString: callId) else { return }
        currentCallId = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = handle
        update.hasVideo = hasVideo
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if error != nil, self?.currentCallId == uuid {
                self?.currentCallId = nil
            }
        }
    }

    /// Reports an app-initiated outgoing call. Unlike incoming calls, this
    /// never goes through CXStartCallAction (no CallKit dialer UI, no
    /// Siri/Recents integration needed) — just enough for CallKit to manage
    /// the audio session the same way it does for incoming calls, so the
    /// caller side gets the same didActivate/didDeactivate audio bridge
    /// instead of relying on WebRTC's own (occasionally racy) auto-activation.
    func reportOutgoingCall(callId: String, handle: String) {
        guard let uuid = UUID(uuidString: callId) else { return }
        currentCallId = uuid
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
    }

    func reportOutgoingCallConnected(callId: String) {
        guard let uuid = UUID(uuidString: callId), uuid == currentCallId else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// Dismisses the CallKit UI for any reason the call ended that didn't
    /// originate from a CallKit action itself (remote hangup/cancel, local
    /// no-answer timeout, busy).
    func endCall(callId: String) {
        guard let uuid = UUID(uuidString: callId), uuid == currentCallId else { return }
        provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
        currentCallId = nil
    }

    func providerDidReset(_ provider: CXProvider) {
        currentCallId = nil
    }

    // CallKit takes exclusive ownership of AVAudioSession once a call is
    // reported — WebRTC's own RTCAudioSession must be told explicitly when
    // that happens, or its internal activation refcount never increments and
    // the mic never actually starts capturing (remote side hears silence)
    // even though the call otherwise looks connected.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        channel?.invokeMethod("callAnswered", arguments: ["callId": action.callUUID.uuidString])
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        channel?.invokeMethod("callEnded", arguments: ["callId": action.callUUID.uuidString])
        if currentCallId == action.callUUID { currentCallId = nil }
        action.fulfill()
    }
}
