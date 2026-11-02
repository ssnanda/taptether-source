import UIKit
import Flutter
import workmanager_apple
import UserNotifications
import AVFoundation

// Flutter 3.41+ creates its implicit engine during UIScene startup.
// At didFinishLaunching the app delegate's window is often nil, so
// platform channels must register with the engine, not the window.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var cloudFolder: TapTetherCloudFolder?
  private var backgroundRefreshChannel: FlutterMethodChannel?
  private var soundMeter: TapTetherSoundMeter?
  private var tvControls: TapTetherTVControlsBridge?

  func didInitializeImplicitFlutterEngine(
    _ engineBridge: FlutterImplicitEngineBridge
  ) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let folder = TapTetherCloudFolder()
    folder.register(messenger: engineBridge.applicationRegistrar.messenger())
    cloudFolder = folder
    let meter = TapTetherSoundMeter()
    meter.register(messenger: engineBridge.applicationRegistrar.messenger())
    soundMeter = meter
    let controls = TapTetherTVControlsBridge()
    controls.register(messenger: engineBridge.applicationRegistrar.messenger())
    tvControls = controls
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


/// Microphone-only ambient audio amplitude measurements. No audio files,
/// recordings, network requests, or speech analysis.
final class TapTetherSoundMeter {
  private var channel: FlutterMethodChannel?
  private var engine: AVAudioEngine?
  private var timer: Timer?
  private var dbfs = -80.0

  func register(messenger: FlutterBinaryMessenger) {
    let bridge = FlutterMethodChannel(
      name: "taptether/sound-meter", binaryMessenger: messenger)
    channel = bridge
    bridge.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "METER_UNAVAILABLE",
          message: "Sound meter not available", details: nil))
        return
      }
      switch call.method {
      case "start":
        self.requestPermissionAndStart(result: result)
      case "stop":
        self.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NotificationCenter.default.addObserver(
      self, selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  @objc private func appDidEnterBackground() {
    stop()
  }

  private func requestPermissionAndStart(result: @escaping FlutterResult) {
    let respond: (Bool) -> Void = { [weak self] granted in
      DispatchQueue.main.async {
        guard let self = self else { result(false); return }
        if !granted { result(false); return }
        do {
          try self.start()
          result(true)
        } catch {
          self.stop()
          result(FlutterError(code: "METER_START_FAILED",
            message: "Microphone monitoring could not start",
            details: nil))
        }
      }
    }
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission(completionHandler: respond)
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission(respond)
    }
  }

  private func start() throws {
    if engine != nil { return }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement, options: [])
    try session.setActive(true)
    let audioEngine = AVAudioEngine()
    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw NSError(domain: "TapTetherSoundMeter", code: 1)
    }
    input.installTap(onBus: 0, bufferSize: 2048, format: format) {
      [weak self] buffer, _ in
      guard let samples = buffer.floatChannelData?[0] else { return }
      let count = Int(buffer.frameLength)
      guard count > 0 else { return }
      var squares = 0.0
      for index in 0..<count {
        let value = Double(samples[index])
        squares += value * value
      }
      let rms = sqrt(squares / Double(count))
      let measured = max(-80.0, min(0.0, 20.0 * log10(max(rms, 0.00001))))
      DispatchQueue.main.async { [weak self] in
        self?.dbfs = measured
      }
    }
    do {
      audioEngine.prepare()
      try audioEngine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw error
    }
    engine = audioEngine
    dbfs = -80
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) {
      [weak self] _ in
      guard let self = self, self.engine != nil else { return }
      self.channel?.invokeMethod("level", arguments: ["dbfs": self.dbfs])
    }
  }

  private func stop() {
    timer?.invalidate()
    timer = nil
    if let engine = engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    engine = nil
    dbfs = -80
    try? AVAudioSession.sharedInstance().setActive(
      false, options: .notifyOthersOnDeactivation)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    stop()
  }
}
