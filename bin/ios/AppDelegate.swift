import UIKit
import Flutter

// Flutter 3.41+ creates its implicit engine during UIScene startup.
// At didFinishLaunching the app delegate's window is often nil, so
// platform channels must register with the engine, not the window.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var cloudFolder: TapTetherCloudFolder?

  func didInitializeImplicitFlutterEngine(
    _ engineBridge: FlutterImplicitEngineBridge
  ) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let folder = TapTetherCloudFolder()
    folder.register(messenger: engineBridge.applicationRegistrar.messenger())
    cloudFolder = folder
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application,
                             didFinishLaunchingWithOptions: launchOptions)
  }
}
