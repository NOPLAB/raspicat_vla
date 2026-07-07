import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // ARKit の VIO 姿勢/フレーム取得プラグイン (app/logger 独自)。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ArPosePlugin") {
      ArPosePlugin.register(with: registrar)
    }
  }
}
