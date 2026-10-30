import UIKit
import Flutter
import workmanager_apple
import UserNotifications

// Flutter 3.41+ creates its implicit engine during UIScene startup.
// At didFinishLaunching the app delegate's window is often nil, so
// platform channels must register with the engine, not the window.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var cloudFolder: TapTetherCloudFolder?
  private var backgroundRefreshChannel: FlutterMethodChannel?

  func didInitializeImplicitFlutterEngine(
    _ engineBridge: FlutterImplicitEngineBridge
  ) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let folder = TapTetherCloudFolder()
    folder.register(messenger: engineBridge.applicationRegistrar.messenger())
    cloudFolder = folder
    let channel = FlutterMethodChannel(
      name: "taptether/background-refresh",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "status" else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch UIApplication.shared.backgroundRefreshStatus {
      case .available: result("available")
      case .denied: result("denied")
      case .restricted: result("restricted")
      @unknown default: result("unknown")
      }
    }
    backgroundRefreshChannel = channel
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register background task handlers before UIKit's launch completes.
    // The background Flutter engine needs its own plugin registration for
    // Keychain, local notifications and network requests.
    WorkmanagerPlugin.registerLaunchHandlers()
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // Required for flutter_local_notifications foreground banners.
    // The app delegate retains this weakly referenced notification delegate.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application,
                             didFinishLaunchingWithOptions: launchOptions)
  }
}
