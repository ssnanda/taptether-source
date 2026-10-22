import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var cloudFolder: TapTetherCloudFolder?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let folder = TapTetherCloudFolder()
      folder.register(controller)
      cloudFolder = folder
    }
    return super.application(application,
                             didFinishLaunchingWithOptions: launchOptions)
  }
}
