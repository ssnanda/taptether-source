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
