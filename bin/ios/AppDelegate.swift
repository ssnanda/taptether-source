import UIKit
import Flutter
import workmanager_apple
import UserNotifications
import AVFoundation
import CoreMotion

// Flutter 3.41+ creates its implicit engine during UIScene startup.
// At didFinishLaunching the app delegate's window is often nil, so
// platform channels must register with the engine, not the window.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var cloudFolder: TapTetherCloudFolder?
  private var backgroundRefreshChannel: FlutterMethodChannel?
  private var soundMeter: TapTetherSoundMeter?
  private var tvControls: TapTetherTVControlsBridge?
  private var phoneOrientation: TapTetherOrientationBridge?

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
    let orientation = TapTetherOrientationBridge()
    orientation.register(messenger: engineBridge.applicationRegistrar.messenger())
    phoneOrientation = orientation
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
    if #available(iOS 18.0, *) {
      TapTetherTVActivityExpiry.register()
    }
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


/// Face ID phones ignore UIKit's portrait-upside-down interface option.
/// Send a debounced physical orientation to Flutter for a 180° app-only turn.
final class TapTetherOrientationBridge: NSObject, FlutterStreamHandler {
  private let motion = CMMotionManager()
  private var sink: FlutterEventSink?
  private var current = false
  private var candidate: Bool?
  private var candidateSince = Date()

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterEventChannel(
      name: "taptether/physical-orientation",
      binaryMessenger: messenger)
    channel.setStreamHandler(self)
    NotificationCenter.default.addObserver(
      self, selector: #selector(didEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(willEnterForeground),
      name: UIApplication.willEnterForegroundNotification, object: nil)
  }

  func onListen(withArguments arguments: Any?,
      eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    start()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stop()
    sink = nil
    return nil
  }

  private func start() {
    guard sink != nil, motion.isAccelerometerAvailable,
          !motion.isAccelerometerActive else { return }
    motion.accelerometerUpdateInterval = 0.12
    motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
      guard let self = self, let acceleration = data?.acceleration else {
        return
      }
      self.observe(
        x: acceleration.x, y: acceleration.y, z: acceleration.z)
    }
  }

  private func observe(x: Double, y: Double, z: Double) {
    // Ignore flat phones and transitional angles; don't flip while swiping.
    if abs(z) > 0.7 { candidate = nil; return }
    let next: Bool
    if y > 0.77 && abs(x) < 0.55 {
      next = true
    } else if y < -0.77 && abs(x) < 0.55 {
      next = false
    } else if abs(x) > 0.77 && abs(y) < 0.55 {
      next = false // Let native iOS handle normal landscape rotation.
    } else {
      candidate = nil
      return
    }
    if next == current { candidate = nil; return }
    if candidate != next {
      candidate = next
      candidateSince = Date()
      return
    }
    guard Date().timeIntervalSince(candidateSince) >= 0.36 else {
      return
    }
    current = next
    candidate = nil
    sink?(current)
  }

  private func stop() {
    motion.stopAccelerometerUpdates()
    candidate = nil
  }

  @objc private func didEnterBackground() { stop() }
  @objc private func willEnterForeground() { start() }

  deinit {
    stop()
    NotificationCenter.default.removeObserver(self)
  }
}

/// Microphone-only ambient audio amplitude measurements. No audio files,
/// recordings, network requests, or speech analysis.
final class TapTetherSoundMeter {
  private var channel: FlutterMethodChannel?
  private var engine: AVAudioEngine?
  private var timer: Timer?
  private var dbfs = -80.0
  private var microphoneName = "Phone microphone"

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
    // Ask for the physical lower/bottom input so pointing the USB-C end
    // toward the TV yields a repeatable ambient-level comparison.
    // Some devices expose no selectable sources; their system default wins.
    if let builtIn = session.availableInputs?.first(where: {
      $0.portType == .builtInMic
    }) {
      try? session.setPreferredInput(builtIn)
      if let bottom = builtIn.dataSources?.first(where: {
        $0.orientation == .bottom || $0.location == .lower
      }) {
        try? builtIn.setPreferredDataSource(bottom)
      }
    }
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
    if let input = session.currentRoute.inputs.first(where: {
      $0.portType == .builtInMic
    }) {
      let source = input.selectedDataSource
      microphoneName =
        (source?.orientation == .bottom || source?.location == .lower)
          ? "Bottom microphone" : "Phone microphone"
    } else {
      microphoneName = "External microphone"
    }
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) {
      [weak self] _ in
      guard let self = self, self.engine != nil else { return }
      self.channel?.invokeMethod("level", arguments: [
        "dbfs": self.dbfs, "microphone": self.microphoneName])
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
