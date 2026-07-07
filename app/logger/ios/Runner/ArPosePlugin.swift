// ARKit で背面カメラの VIO 姿勢とカメラフレームを取り出し、Flutter へ流すプラグイン。
//
// AR (ARKit) が背面カメラを占有するため、logger アプリはフレームも姿勢も AR から取る。
// プレビュー用の ARSCNView がセッションを所有し、本プラグインがそのデリゲートとして
// 各フレームを受け取り、EventChannel にリスナが付いている間だけ間引いて流す。
// JPEG エンコード・中解像度への縮小はここ (端末側) で行う。時刻打ちは Dart 側 (共有
// MonoClock) が受信時に行うので、ここでは時刻を送らない。
//
// チャネル契約は lib/src/capture/ar_session.dart と一致させること。

import ARKit
import CoreImage
import Flutter
import SceneKit
import UIKit

private let kPrefix = "com.raspicat.vla_logger/ar"

// EventChannel のリスナ着脱を単なる sink 保持にするヘルパ。
class ArStreamHandler: NSObject, FlutterStreamHandler {
  var onListen: ((FlutterEventSink?) -> Void)?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    onListen?(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onListen?(nil)
    return nil
  }
}

public class ArPosePlugin: NSObject, FlutterPlugin, ARSessionDelegate {
  private var poseSink: FlutterEventSink?
  private var frameSink: FlutterEventSink?

  private var cameraHz: Double = 4.0
  private var poseHz: Double = 30.0
  private var jpegQuality: Double = 0.85

  private var lastFrameEmit: TimeInterval = 0
  private var lastPoseEmit: TimeInterval = 0
  private var running = false

  // プレビュー ARSCNView が所有するセッション (弱参照)。start より後に生成されうる。
  private weak var session: ARSession?

  private let ciContext = CIContext()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = ArPosePlugin()

    let control = FlutterMethodChannel(
      name: "\(kPrefix)/ar_control", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: control)

    let poseHandler = ArStreamHandler()
    poseHandler.onListen = { [weak instance] sink in instance?.poseSink = sink }
    let poseCh = FlutterEventChannel(
      name: "\(kPrefix)/ar_pose", binaryMessenger: registrar.messenger())
    poseCh.setStreamHandler(poseHandler)

    let frameHandler = ArStreamHandler()
    frameHandler.onListen = { [weak instance] sink in instance?.frameSink = sink }
    let frameCh = FlutterEventChannel(
      name: "\(kPrefix)/ar_frame", binaryMessenger: registrar.messenger())
    frameCh.setStreamHandler(frameHandler)

    let factory = ArPreviewFactory(plugin: instance)
    registrar.register(factory, withId: "\(kPrefix)/ar_preview")

    // ハンドラを解放させないため保持。
    instance.retained = [poseHandler, frameHandler]
  }

  private var retained: [Any] = []

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(ARWorldTrackingConfiguration.isSupported)
    case "start":
      if let args = call.arguments as? [String: Any] {
        cameraHz = (args["cameraHz"] as? NSNumber)?.doubleValue ?? cameraHz
        poseHz = (args["poseHz"] as? NSNumber)?.doubleValue ?? poseHz
        if let q = (args["jpegQuality"] as? NSNumber)?.doubleValue { jpegQuality = q / 100.0 }
      }
      running = true
      runSessionIfPossible()
      result(nil)
    case "stop":
      running = false
      session?.pause()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // プレビュー view からセッションを受け取る (start より前後どちらでも動くように)。
  func attach(session: ARSession) {
    self.session = session
    session.delegate = self
    runSessionIfPossible()
  }

  func detach(session: ARSession) {
    if self.session === session { self.session = nil }
  }

  private func runSessionIfPossible() {
    guard running, let session = session else { return }
    let config = ARWorldTrackingConfiguration()
    config.worldAlignment = .gravity  // 重力整列: Y 上、原点は初期カメラ位置。
    session.run(config, options: [])
  }

  // MARK: - ARSessionDelegate

  public func session(_ session: ARSession, didUpdate frame: ARFrame) {
    let t = frame.timestamp  // 単調 (CACurrentMediaTime 系)。間引き判定にのみ使う。

    if let sink = poseSink, t - lastPoseEmit >= 1.0 / poseHz {
      lastPoseEmit = t
      emitPose(frame, to: sink)
    }
    if let sink = frameSink, t - lastFrameEmit >= 1.0 / cameraHz {
      lastFrameEmit = t
      emitFrame(frame, to: sink)
    }
  }

  private func emitPose(_ frame: ARFrame, to sink: FlutterEventSink) {
    let m = frame.camera.transform
    let pos = m.columns.3
    let q = simd_quatf(m)  // 回転部分からクォータニオンを取り出す。
    let state: String
    switch frame.camera.trackingState {
    case .normal: state = "normal"
    case .limited: state = "limited"
    case .notAvailable: state = "notAvailable"
    }
    sink([
      "tx": pos.x, "ty": pos.y, "tz": pos.z,
      "qx": q.imag.x, "qy": q.imag.y, "qz": q.imag.z, "qw": q.real,
      "tracking_state": state,
    ])
  }

  private func emitFrame(_ frame: ARFrame, to sink: FlutterEventSink) {
    let pixelBuffer = frame.capturedImage
    var ci = CIImage(cvPixelBuffer: pixelBuffer)
    let w = ci.extent.width
    // 中解像度化: 長辺を ~640 に縮小 (spec の中解像度フルフレーム方針)。crop はしない。
    if w > 640 {
      let scale = 640.0 / w
      ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
    guard
      let jpeg = ciContext.jpegRepresentation(
        of: ci, colorSpace: CGColorSpaceCreateDeviceRGB(),
        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality])
    else { return }
    sink([
      "jpeg": FlutterStandardTypedData(bytes: jpeg),
      "width": Int(ci.extent.width),
      "height": Int(ci.extent.height),
    ])
  }
}

// MARK: - プレビュー PlatformView (ARSCNView がセッションを所有)

class ArPreviewFactory: NSObject, FlutterPlatformViewFactory {
  private weak var plugin: ArPosePlugin?
  init(plugin: ArPosePlugin) { self.plugin = plugin }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?)
    -> FlutterPlatformView
  {
    return ArPreviewView(frame: frame, plugin: plugin)
  }
}

class ArPreviewView: NSObject, FlutterPlatformView {
  private let arView: ARSCNView
  private weak var plugin: ArPosePlugin?

  init(frame: CGRect, plugin: ArPosePlugin?) {
    self.arView = ARSCNView(frame: frame)
    self.plugin = plugin
    super.init()
    plugin?.attach(session: arView.session)
  }

  func view() -> UIView { arView }

  deinit {
    plugin?.detach(session: arView.session)
  }
}
