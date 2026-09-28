import UIKit
import Flutter

/// Real iOS 26+ Liquid Glass material, hosted as a Flutter platform view.
/// Renders ONLY the glass background — icons/text/taps stay in Flutter,
/// drawn on top of this view's bounds, so localisation, badges and gesture
/// handling all keep working exactly as before. Falls back to UIBlurEffect
/// on iOS < 26 (RlinkDesign.frosted() is the only caller; see its comment).
class LiquidGlassPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger
    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        let params = args as? [String: Any]
        let radius = (params?["radius"] as? Double) ?? 0
        return LiquidGlassPlatformView(frame: frame, radius: CGFloat(radius))
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}

class LiquidGlassPlatformView: NSObject, FlutterPlatformView {
    private let effectView: UIVisualEffectView

    init(frame: CGRect, radius: CGFloat) {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            effect = UIGlassEffect()
        } else {
            effect = UIBlurEffect(style: .systemMaterial)
        }
        effectView = UIVisualEffectView(effect: effect)
        effectView.frame = frame
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        effectView.layer.cornerRadius = radius
        effectView.clipsToBounds = true
        super.init()
    }

    func view() -> UIView { effectView }
}
