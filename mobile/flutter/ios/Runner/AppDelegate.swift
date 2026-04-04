import ActivityKit
import AVFoundation
import AVKit
import BackgroundTasks
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let backgroundKeepAlive = BackgroundKeepAliveController()
  private let pictureInPicture = NativePictureInPictureController()
  private var backgroundChannel: FlutterMethodChannel?
  private var liveActivitiesChannel: FlutterMethodChannel?
  private var nativeInlinePlayerRegistered = false
  // Stored as Any? so we can guard availability at runtime without the
  // "stored property cannot be marked @available" compiler error.
  private var _liveActivities: Any?

  @available(iOS 16.2, *)
  private var liveActivities: LiveActivitiesController {
    if _liveActivities == nil {
      _liveActivities = LiveActivitiesController()
    }
    return _liveActivities as! LiveActivitiesController
  }

  private static let bgTaskIdentifier = "com.iptvgrab.app.downloads"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    MobileFfiForceLink()
    configureAudioSession()
    registerBGTasks()
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    registerNativeInlinePlayer(with: self)
    installBackgroundChannel()
    installLiveActivitiesChannel()
    DispatchQueue.main.async { [weak self] in
      self?.installBackgroundChannel()
      self?.installLiveActivitiesChannel()
    }
    return launched
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerNativeInlinePlayer(with: engineBridge.pluginRegistry)
    installBackgroundChannel()
    installLiveActivitiesChannel()
    // Fallback: register directly via engine registrar messenger in case
    // window?.rootViewController is not yet a FlutterViewController.
    if liveActivitiesChannel == nil,
      let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LiveActivitiesPlugin")
    {
      installLiveActivitiesChannelWith(messenger: registrar.messenger())
    }
  }

  private func registerNativeInlinePlayer(with registry: FlutterPluginRegistry) {
    guard !nativeInlinePlayerRegistered,
      let registrar = registry.registrar(forPlugin: "NativeInlinePlayer")
    else { return }
    registrar.register(
      NativeInlinePlayerFactory(messenger: registrar.messenger()),
      withId: "iptvgrab/native-inline-player"
    )
    nativeInlinePlayerRegistered = true
  }

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
      try session.setActive(true)
    } catch {
      NSLog("Failed to configure AVAudioSession for video playback: \(error)")
    }
  }

  // MARK: - BGTaskScheduler

  private func registerBGTasks() {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: AppDelegate.bgTaskIdentifier,
      using: nil
    ) { [weak self] task in
      self?.handleDownloadProcessingTask(task as! BGProcessingTask)
    }
  }

  // Keeps the process alive while the Rust server downloads in the background.
  // The system calls this when it decides to grant background execution time
  // (typically when the device is idle or charging).
  private func handleDownloadProcessingTask(_ task: BGProcessingTask) {
    task.expirationHandler = {
      NSLog("[BGTask] download-continuation expired")
      task.setTaskCompleted(success: false)
    }
    // The Rust server keeps downloading on its own. We just need to stay alive.
    // The task is effectively "done" from our side — the server does the work.
    // We mark success so the scheduler knows we ran cleanly.
    task.setTaskCompleted(success: true)
  }

  private func installBackgroundChannel() {
    guard backgroundChannel == nil,
      let controller = window?.rootViewController as? FlutterViewController
    else {
      return
    }

    let channel = FlutterMethodChannel(
      name: "iptvgrab/background-control",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "app_deallocated",
            message: "The app delegate is no longer available.",
            details: nil
          )
        )
        return
      }

      switch call.method {
      case "setKeepAlive":
        let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
        do {
          try self.backgroundKeepAlive.setEnabled(enabled)
          if enabled {
            self.scheduleBGProcessingTask()
          } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppDelegate.bgTaskIdentifier)
          }
          result(nil)
        } catch {
          result(
            FlutterError(
              code: "keep_alive_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }

      case "enterPictureInPicture":
        let arguments = call.arguments as? [String: Any] ?? [:]
        let urlString = arguments["url"] as? String ?? ""
        let headers = arguments["headers"] as? [String: String] ?? [:]
        let positionMillis = arguments["positionMillis"] as? Int ?? 0
        // start() is async — it calls result() when PiP has started or failed
        self.pictureInPicture.start(
          urlString: urlString,
          headers: headers,
          positionMillis: positionMillis,
          hostViewController: controller,
          result: result
        )

      default:
        result(FlutterMethodNotImplemented)
      }
    }
    backgroundChannel = channel
  }

  private func installLiveActivitiesChannel() {
    guard liveActivitiesChannel == nil,
      let controller = window?.rootViewController.flatMap({ Self.findFlutterVC(in: $0) })
    else { return }
    installLiveActivitiesChannelWith(messenger: controller.binaryMessenger)
  }

  private func installLiveActivitiesChannelWith(messenger: FlutterBinaryMessenger) {
    guard liveActivitiesChannel == nil else { return }
    let channel = FlutterMethodChannel(
      name: "iptvgrab/live-activities",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      guard #available(iOS 16.2, *) else {
        result(
          FlutterError(
            code: "unsupported",
            message: "Live Activities require iOS 16.2+",
            details: nil
          )
        )
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "startLiveActivity":
        let taskId = args["taskId"] as? String ?? ""
        let taskName = args["taskName"] as? String ?? "Download"
        let isRecording = args["isRecording"] as? Bool ?? false
        self.liveActivities.start(
          taskId: taskId, taskName: taskName, isRecording: isRecording)
        result(nil)
      case "updateLiveActivity":
        let taskId = args["taskId"] as? String ?? ""
        let progress = args["progress"] as? Double ?? 0
        let speedMbps = args["speedMbps"] as? Double ?? 0
        let done = args["done"] as? Int ?? 0
        let total = args["total"] as? Int ?? 0
        let status = args["status"] as? String ?? ""
        let elapsedSec = args["elapsedSec"] as? Int ?? 0
        self.liveActivities.update(
          taskId: taskId,
          progress: progress,
          speedMbps: speedMbps,
          done: done,
          total: total,
          status: status,
          elapsedSec: elapsedSec
        )
        result(nil)
      case "endLiveActivity":
        let taskId = args["taskId"] as? String ?? ""
        self.liveActivities.end(taskId: taskId)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    liveActivitiesChannel = channel
    NSLog("[LiveActivity] Method channel registered")
  }

  // Walk the VC hierarchy to find a FlutterViewController (handles cases
  // where it's embedded in a navigation or presentation container).
  private static func findFlutterVC(in vc: UIViewController) -> FlutterViewController? {
    if let fvc = vc as? FlutterViewController { return fvc }
    for child in vc.children {
      if let found = findFlutterVC(in: child) { return found }
    }
    if let presented = vc.presentedViewController {
      return findFlutterVC(in: presented)
    }
    return nil
  }

  private func scheduleBGProcessingTask() {    let request = BGProcessingTaskRequest(identifier: AppDelegate.bgTaskIdentifier)
    request.requiresNetworkConnectivity = true
    request.requiresExternalPower = false
    do {
      try BGTaskScheduler.shared.submit(request)
      NSLog("[BGTask] Scheduled download-continuation processing task")
    } catch {
      NSLog("[BGTask] Failed to schedule: \(error)")
    }
  }
}

private final class BackgroundKeepAliveController {
  private var audioPlayer: AVAudioPlayer?
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var enabled = false

  init() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance()
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func setEnabled(_ shouldEnable: Bool) throws {
    if shouldEnable {
      try start()
    } else {
      stop()
    }
  }

  // Restart audio playback after a phone call, Siri, or other interruption
  // so the keep-alive doesn't silently stop working.
  @objc private func handleAudioSessionInterruption(_ notification: Notification) {
    guard enabled,
      let info = notification.userInfo,
      let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else { return }

    if type == .ended {
      NSLog("[KeepAlive] Audio session interruption ended — restarting silent audio")
      let session = AVAudioSession.sharedInstance()
      try? session.setActive(true)
      audioPlayer?.play()
    }
  }

  private func start() throws {
    guard !enabled else { return }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
    try session.setActive(true)

    let player = try AVAudioPlayer(data: Self.makeSilentLoopWav())
    player.numberOfLoops = -1
    player.volume = 0
    player.prepareToPlay()
    guard player.play() else {
      throw NSError(
        domain: "MediaNestBackgroundKeepAlive",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Silent keepalive audio failed to start."]
      )
    }

    audioPlayer = player
    beginBackgroundTask()
    enabled = true
  }

  private func stop() {
    guard enabled else { return }
    audioPlayer?.stop()
    audioPlayer = nil
    endBackgroundTask()
    enabled = false
  }

  private func beginBackgroundTask() {
    guard backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Media Nest downloads") {
      [weak self] in
      self?.endBackgroundTask()
    }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  private static func makeSilentLoopWav(
    sampleRate: Int = 44_100,
    durationSeconds: Int = 1
  ) -> Data {
    let channels = 1
    let bitsPerSample = 16
    let blockAlign = channels * bitsPerSample / 8
    let byteRate = sampleRate * blockAlign
    let dataSize = sampleRate * durationSeconds * blockAlign
    let riffSize = 36 + dataSize

    var data = Data()

    func appendASCII(_ value: String) {
      data.append(value.data(using: .ascii)!)
    }

    func appendUInt16(_ value: UInt16) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    func appendUInt32(_ value: UInt32) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    appendASCII("RIFF")
    appendUInt32(UInt32(riffSize))
    appendASCII("WAVE")
    appendASCII("fmt ")
    appendUInt32(16)
    appendUInt16(1)
    appendUInt16(UInt16(channels))
    appendUInt32(UInt32(sampleRate))
    appendUInt32(UInt32(byteRate))
    appendUInt16(UInt16(blockAlign))
    appendUInt16(UInt16(bitsPerSample))
    appendASCII("data")
    appendUInt32(UInt32(dataSize))
    data.append(Data(count: dataSize))
    return data
  }
}

// Uses AVPlayerLayer + AVPictureInPictureController (iOS 9+ API) so that
// startPictureInPicture() / stopPictureInPicture() are always available.
// AVPlayerViewController.startPictureInPicture() was removed in iOS 26.
// The player layer is embedded in a tiny invisible view that is added to
// the host view controller's hierarchy — PiP requires the layer to be
// in a window.
private final class NativePictureInPictureController: NSObject, AVPictureInPictureControllerDelegate {
  private var player: AVPlayer?
  private var playerLayer: AVPlayerLayer?
  private var containerView: UIView?
  private var pipController: AVPictureInPictureController?
  private var itemStatusObservation: NSKeyValueObservation?
  private var pipPossibleObservation: NSKeyValueObservation?
  private var pendingResult: FlutterResult?

  func start(
    urlString: String,
    headers: [String: String],
    positionMillis: Int,
    hostViewController: UIViewController,
    result: @escaping FlutterResult
  ) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      NSLog("[PiP] isPictureInPictureSupported() = false")
      result(
        FlutterError(
          code: "pip_not_supported",
          message: "Picture in Picture is not supported on this device or OS version.",
          details: nil
        )
      )
      return
    }
    guard let url = URL(string: urlString) else {
      NSLog("[PiP] Invalid URL: \(urlString)")
      result(false)
      return
    }

    stopCurrentSession()

    var assetOptions: [String: Any] = [:]
    if !headers.isEmpty {
      assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    let asset = AVURLAsset(url: url, options: assetOptions.isEmpty ? nil : assetOptions)
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = true

    if positionMillis > 0 {
      let seekTime = CMTime(value: CMTimeValue(positionMillis), timescale: 1_000)
      player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // Embed a 2×2 invisible container view in the host window hierarchy.
    // AVPictureInPictureController requires the player layer to be in a window.
    let container = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
    container.alpha = 0.01
    hostViewController.view.addSubview(container)

    let layer = AVPlayerLayer(player: player)
    layer.frame = container.bounds
    container.layer.addSublayer(layer)

    let pip = AVPictureInPictureController(playerLayer: layer)
    pip?.delegate = self
    if #available(iOS 14.2, *) {
      pip?.canStartPictureInPictureAutomaticallyFromInline = true
    }

    self.player = player
    self.playerLayer = layer
    self.containerView = container
    self.pipController = pip
    self.pendingResult = result

    player.play()

    // Wait for the player item to become ready before triggering PiP.
    itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
      guard let self else { return }
      switch item.status {
      case .readyToPlay:
        self.itemStatusObservation?.invalidate()
        self.itemStatusObservation = nil
        NSLog("[PiP] AVPlayerItem readyToPlay — waiting for isPictureInPicturePossible")
        DispatchQueue.main.async { self.waitForPiPPossibleThenLaunch() }
      case .failed:
        self.itemStatusObservation?.invalidate()
        self.itemStatusObservation = nil
        NSLog("[PiP] AVPlayerItem failed: \(item.error?.localizedDescription ?? "unknown")")
        DispatchQueue.main.async {
          self.finishWithResult(false)
          self.cleanup()
        }
      default:
        break
      }
    }

    // Fallback: attempt after 5 s even if readyToPlay never fires (common for
    // live HLS streams that linger in .unknown status).
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
      guard let self, self.itemStatusObservation != nil else { return }
      self.itemStatusObservation?.invalidate()
      self.itemStatusObservation = nil
      NSLog("[PiP] readyToPlay timeout — attempting startPictureInPicture() anyway")
      self.launchPiP()
    }
  }

  private func waitForPiPPossibleThenLaunch() {
    guard let pip = pipController else { finishWithResult(false); return }
    if pip.isPictureInPicturePossible {
      launchPiP()
      return
    }
    // Observe until it becomes possible (or timeout).
    pipPossibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] pip, _ in
      guard let self, pip.isPictureInPicturePossible else { return }
      self.pipPossibleObservation?.invalidate()
      self.pipPossibleObservation = nil
      DispatchQueue.main.async { self.launchPiP() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
      guard let self, self.pipPossibleObservation != nil else { return }
      self.pipPossibleObservation?.invalidate()
      self.pipPossibleObservation = nil
      NSLog("[PiP] isPictureInPicturePossible timeout — attempting anyway")
      self.launchPiP()
    }
  }

  private func launchPiP() {
    guard let pip = pipController else {
      finishWithResult(false)
      return
    }
    #if !targetEnvironment(simulator)
    pip.startPictureInPicture()
    // Safety timeout in case the delegate never fires.
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
      guard let self, self.pendingResult != nil else { return }
      NSLog("[PiP] startPictureInPicture() delegate timeout")
      self.finishWithResult(false)
      self.cleanup()
    }
    #else
    NSLog("[PiP] startPictureInPicture() not available on simulator")
    finishWithResult(false)
    cleanup()
    #endif
  }

  // MARK: - AVPictureInPictureControllerDelegate

  func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    NSLog("[PiP] willStartPictureInPicture")
    finishWithResult(true)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    NSLog("[PiP] failedToStartPictureInPictureWithError: \(error)")
    finishWithResult(false)
    cleanup()
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    NSLog("[PiP] didStopPictureInPicture")
    cleanup()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }

  // MARK: - Helpers

  private func finishWithResult(_ value: Any?) {
    pendingResult?(value)
    pendingResult = nil
  }

  private func stopCurrentSession() {
    itemStatusObservation?.invalidate()
    itemStatusObservation = nil
    pipPossibleObservation?.invalidate()
    pipPossibleObservation = nil
    pendingResult = nil
    cleanup()
  }

  private func cleanup() {
    itemStatusObservation?.invalidate()
    itemStatusObservation = nil
    pipPossibleObservation?.invalidate()
    pipPossibleObservation = nil
    player?.pause()
    player = nil
    if let pip = pipController {
      pip.delegate = nil
      #if !targetEnvironment(simulator)
      pip.stopPictureInPicture()
      #endif
    }
    pipController = nil
    playerLayer?.removeFromSuperlayer()
    playerLayer = nil
    containerView?.removeFromSuperview()
    containerView = nil
  }
}

private final class NativePlayerHostView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }

  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private final class NativeInlinePlayerFactory: NSObject, FlutterPlatformViewFactory {
  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  private let messenger: FlutterBinaryMessenger

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    NativeInlinePlayerPlatformView(
      frame: frame,
      viewIdentifier: viewId,
      arguments: args as? [String: Any] ?? [:],
      messenger: messenger
    )
  }
}

private final class NativeInlinePlayerPlatformView: NSObject, FlutterPlatformView, FlutterStreamHandler,
  AVPictureInPictureControllerDelegate
{
  private let hostView: NativePlayerHostView
  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel

  private var eventSink: FlutterEventSink?
  private var player: AVPlayer?
  private var playerItem: AVPlayerItem?
  private var pipController: AVPictureInPictureController?
  private var playerItemStatusObservation: NSKeyValueObservation?
  private var playerTimeControlObservation: NSKeyValueObservation?
  private var pipPossibleObservation: NSKeyValueObservation?
  private var pipActiveObservation: NSKeyValueObservation?
  private var periodicTimeObserver: Any?
  private var itemDidPlayToEndObserver: NSObjectProtocol?
  private var pendingPiPResult: FlutterResult?
  private var pendingPiPWorkItem: DispatchWorkItem?
  private var initialized = false
  private var lastError: String?
  private var isLive = false
  private var diagnostics: [String] = []

  init(
    frame: CGRect,
    viewIdentifier: Int64,
    arguments: [String: Any],
    messenger: FlutterBinaryMessenger
  ) {
    hostView = NativePlayerHostView(frame: frame)
    hostView.backgroundColor = .black
    hostView.playerLayer.videoGravity = .resizeAspect
    methodChannel = FlutterMethodChannel(
      name: "iptvgrab/native-player/\(viewIdentifier)/method",
      binaryMessenger: messenger
    )
    eventChannel = FlutterEventChannel(
      name: "iptvgrab/native-player/\(viewIdentifier)/events",
      binaryMessenger: messenger
    )
    super.init()
    eventChannel.setStreamHandler(self)
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    configure(arguments: arguments)
  }

  deinit {
    cleanup()
  }

  func view() -> UIView {
    hostView
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    emitState()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "play":
      player?.play()
      emitState()
      result(nil)
    case "pause":
      player?.pause()
      emitState()
      result(nil)
    case "seekToMillis":
      let positionMillis = (call.arguments as? [String: Any])?["positionMillis"] as? Int ?? 0
      let target = CMTime(value: CMTimeValue(positionMillis), timescale: 1_000)
      player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
      emitState()
      result(nil)
    case "setMuted":
      let muted = (call.arguments as? [String: Any])?["muted"] as? Bool ?? false
      player?.isMuted = muted
      emitState()
      result(nil)
    case "setPreferredBitRate":
      let bandwidth = (call.arguments as? [String: Any])?["bandwidth"] as? Double ?? 0
      player?.currentItem?.preferredPeakBitRate = bandwidth
      emitState()
      result(nil)
    case "enterPictureInPicture":
      enterPictureInPicture(result: result)
    case "dispose":
      cleanup()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func configure(arguments: [String: Any]) {
    isLive = arguments["isLive"] as? Bool ?? false
    let muted = arguments["muted"] as? Bool ?? false
    let headers = arguments["headers"] as? [String: String] ?? [:]
    let urlString = arguments["url"] as? String ?? ""
    guard let url = URL(string: urlString) else {
      lastError = "Invalid media URL: \(urlString)"
      appendDiagnostic(lastError!)
      emitState()
      return
    }

    var assetOptions: [String: Any] = [:]
    if !headers.isEmpty {
      assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    let asset = AVURLAsset(url: url, options: assetOptions.isEmpty ? nil : assetOptions)
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.isMuted = muted
    player.automaticallyWaitsToMinimizeStalling = true
    player.actionAtItemEnd = isLive ? .pause : .none

    hostView.playerLayer.player = player
    self.player = player
    playerItem = item

    let pip = AVPictureInPictureController(playerLayer: hostView.playerLayer)
    pip?.delegate = self
    if #available(iOS 14.2, *) {
      pip?.canStartPictureInPictureAutomaticallyFromInline = true
    }
    pipController = pip
    if pip == nil {
      appendDiagnostic("AVPictureInPictureController could not be created for this player layer.")
    }

    playerItemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      guard let self else { return }
      switch item.status {
      case .readyToPlay:
        self.initialized = true
        self.lastError = nil
        self.appendDiagnostic("The native AVPlayer item is ready to play.")
      case .failed:
        self.initialized = false
        self.lastError = self.describe(error: item.error) ?? "The native AVPlayer item failed."
        if let lastError = self.lastError {
          self.appendDiagnostic(lastError)
        }
        if let errorLog = item.errorLog()?.events.last {
          self.appendDiagnostic(
            "AVPlayerItemErrorLog: domain=\(errorLog.errorDomain) status=\(errorLog.errorStatusCode) comment=\(errorLog.errorComment ?? "n/a") uri=\(errorLog.uri ?? "n/a")"
          )
        }
      case .unknown:
        self.appendDiagnostic("The native AVPlayer item is still in the unknown state.")
      @unknown default:
        self.appendDiagnostic("The native AVPlayer item reported an unknown status value.")
      }
      self.emitState()
    }

    playerTimeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
      guard let self else { return }
      if player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
        let reason = player.reasonForWaitingToPlay?.rawValue
      {
        self.appendDiagnostic("The native AVPlayer is waiting to play: \(reason)")
      }
      self.emitState()
    }

    if let pip {
      pipPossibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] pip, _ in
        guard let self else { return }
        if !pip.isPictureInPicturePossible {
          self.appendDiagnostic(
            "AVPictureInPictureController reports isPictureInPicturePossible = false for the current player state."
          )
        }
        self.emitState()
      }
      pipActiveObservation = pip.observe(\.isPictureInPictureActive, options: [.initial, .new]) { [weak self] _, _ in
        self?.emitState()
      }
    }

    periodicTimeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
      queue: .main
    ) { [weak self] _ in
      self?.emitState()
    }

    if !isLive {
      itemDidPlayToEndObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: item,
        queue: .main
      ) { [weak self] _ in
        guard let self, let player = self.player else { return }
        player.seek(to: .zero)
        player.play()
      }
    }

    // Re-activate the audio session before starting each new player instance to
    // ensure audio is routed correctly after quality switches or interruptions.
    try? AVAudioSession.sharedInstance().setActive(true)
    player.play()
    emitState()
  }

  private func emitState() {
    guard let eventSink else { return }
    var payload: [String: Any] = [
      "type": "state",
      "initialized": initialized,
      "isPlaying": player?.timeControlStatus == .playing,
      "isBuffering": player?.timeControlStatus == .waitingToPlayAtSpecifiedRate,
      "isPictureInPictureSupported": AVPictureInPictureController.isPictureInPictureSupported(),
      "isPictureInPicturePossible": pipController?.isPictureInPicturePossible ?? false,
      "isPictureInPictureActive": pipController?.isPictureInPictureActive ?? false,
      "positionMillis": currentPositionMillis(),
      "durationMillis": currentDurationMillis(),
      "aspectRatio": currentAspectRatio(),
      "diagnostics": diagnostics,
    ]
    if let lastError {
      payload["error"] = lastError
    }
    eventSink(payload)
  }

  private func currentPositionMillis() -> Int {
    guard let time = player?.currentTime(), time.isNumeric else { return 0 }
    return Int((CMTimeGetSeconds(time) * 1000).rounded())
  }

  private func currentDurationMillis() -> Int {
    guard let duration = playerItem?.duration, duration.isNumeric else { return 0 }
    return Int((CMTimeGetSeconds(duration) * 1000).rounded())
  }

  private func currentAspectRatio() -> Double {
    guard let size = playerItem?.presentationSize, size.width > 0, size.height > 0 else {
      return 16.0 / 9.0
    }
    return Double(size.width / size.height)
  }

  private func enterPictureInPicture(result: @escaping FlutterResult) {
    guard pendingPiPResult == nil else {
      result(
        FlutterError(
          code: "pip_busy",
          message: "A Picture in Picture request is already in progress.",
          details: buildPiPFailureDetails()
        )
      )
      return
    }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      result(
        FlutterError(
          code: "pip_not_supported",
          message: "Picture in Picture is not supported on this device or iOS version.",
          details: buildPiPFailureDetails()
        )
      )
      return
    }
    guard let pip = pipController else {
      result(
        FlutterError(
          code: "pip_controller_missing",
          message: "The native Picture in Picture controller could not be created.",
          details: buildPiPFailureDetails()
        )
      )
      return
    }
    guard hostView.window != nil else {
      result(
        FlutterError(
          code: "pip_view_not_visible",
          message: "The native player view is not attached to a visible iOS window yet.",
          details: buildPiPFailureDetails()
        )
      )
      return
    }

    pendingPiPResult = result
    if pip.isPictureInPictureActive {
      finishPendingPiP(with: true)
      return
    }
    if pip.isPictureInPicturePossible {
      startPictureInPicture()
      return
    }

    appendDiagnostic("Delaying Picture in Picture start because isPictureInPicturePossible is still false.")
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.pendingPiPResult != nil else { return }
      if pip.isPictureInPicturePossible {
        self.startPictureInPicture()
        return
      }
      self.failPendingPiP(
        code: "pip_not_possible",
        message: "iOS reported that Picture in Picture is not possible for the current stream state."
      )
    }
    pendingPiPWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
  }

  private func startPictureInPicture() {
    guard let pip = pipController else {
      failPendingPiP(
        code: "pip_controller_missing",
        message: "The native Picture in Picture controller is no longer available."
      )
      return
    }
    pendingPiPWorkItem?.cancel()
    let timeout = DispatchWorkItem { [weak self] in
      self?.failPendingPiP(
        code: "pip_start_timeout",
        message: "Timed out while waiting for iOS to confirm Picture in Picture startup."
      )
    }
    pendingPiPWorkItem = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeout)
    pip.startPictureInPicture()
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    appendDiagnostic("iOS confirmed that Picture in Picture started successfully.")
    finishPendingPiP(with: true)
    emitState()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    appendDiagnostic(
      "Picture in Picture failed to start: \(describe(error: error) ?? String(describing: error))"
    )
    failPendingPiP(
      code: "pip_start_failed",
      message: describe(error: error) ?? "Picture in Picture failed to start."
    )
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    appendDiagnostic("iOS reported that Picture in Picture stopped.")
    emitState()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }

  private func finishPendingPiP(with value: Any?) {
    pendingPiPWorkItem?.cancel()
    pendingPiPWorkItem = nil
    pendingPiPResult?(value)
    pendingPiPResult = nil
  }

  private func failPendingPiP(code: String, message: String) {
    finishPendingPiP(
      with: FlutterError(
        code: code,
        message: message,
        details: buildPiPFailureDetails()
      )
    )
  }

  private func buildPiPFailureDetails() -> [String] {
    var reasons = diagnostics
    if hostView.window == nil {
      reasons.append("The player layer is not attached to a visible UIView window.")
    }
    if player == nil || playerItem == nil {
      reasons.append("The native AVPlayer instance has not been created.")
    }
    if !initialized {
      reasons.append("The native AVPlayer item is not ready to play yet.")
    }
    if let playerItem, playerItem.presentationSize.width <= 0 || playerItem.presentationSize.height <= 0 {
      reasons.append("No video presentation size is available yet, so iOS may reject Picture in Picture.")
    }
    if let pipController, !pipController.isPictureInPicturePossible {
      reasons.append("AVPictureInPictureController still reports isPictureInPicturePossible = false.")
    }
    if let error = describe(error: playerItem?.error) {
      reasons.append("AVPlayerItem error: \(error)")
    }
    return dedupe(reasons)
  }

  private func describe(error: Error?) -> String? {
    guard let error else { return nil }
    let nsError = error as NSError
    return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
  }

  private func appendDiagnostic(_ message: String) {
    let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    if diagnostics.last != normalized {
      diagnostics.append(normalized)
    }
    if diagnostics.count > 20 {
      diagnostics.removeFirst(diagnostics.count - 20)
    }
  }

  private func dedupe(_ messages: [String]) -> [String] {
    var seen = Set<String>()
    var deduped: [String] = []
    for message in messages {
      let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
      seen.insert(normalized)
      deduped.append(normalized)
    }
    return deduped
  }

  private func cleanup() {
    pendingPiPWorkItem?.cancel()
    pendingPiPWorkItem = nil
    pendingPiPResult = nil
    playerItemStatusObservation?.invalidate()
    playerItemStatusObservation = nil
    playerTimeControlObservation?.invalidate()
    playerTimeControlObservation = nil
    pipPossibleObservation?.invalidate()
    pipPossibleObservation = nil
    pipActiveObservation?.invalidate()
    pipActiveObservation = nil
    if let periodicTimeObserver, let player {
      player.removeTimeObserver(periodicTimeObserver)
    }
    periodicTimeObserver = nil
    if let itemDidPlayToEndObserver {
      NotificationCenter.default.removeObserver(itemDidPlayToEndObserver)
      self.itemDidPlayToEndObserver = nil
    }
    pipController?.delegate = nil
    pipController?.stopPictureInPicture()
    pipController = nil
    player?.pause()
    player = nil
    playerItem = nil
    hostView.playerLayer.player = nil
  }
}


// MARK: - LiveActivitiesController

@available(iOS 16.2, *)
private final class LiveActivitiesController {
  private var activities: [String: Activity<DownloadActivityAttributes>] = [:]

  func start(taskId: String, taskName: String, isRecording: Bool) {
    guard activities[taskId] == nil else { return }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      NSLog("[LiveActivity] Activities not enabled (user may have disabled in Settings)")
      return
    }
    let attrs = DownloadActivityAttributes(
      taskId: taskId, taskName: taskName, isRecording: isRecording)
    let initialState = DownloadActivityAttributes.DownloadState(
      progress: 0, speedMbps: 0, done: 0, total: 0,
      status: isRecording ? "recording" : "downloading", elapsedSec: 0)
    do {
      let activity = try Activity.request(
        attributes: attrs,
        content: .init(state: initialState, staleDate: nil),
        pushType: nil
      )
      activities[taskId] = activity
      NSLog("[LiveActivity] Started for task \(taskId)")
    } catch {
      NSLog("[LiveActivity] Failed to start: \(error)")
    }
  }

  func update(
    taskId: String, progress: Double, speedMbps: Double,
    done: Int, total: Int, status: String, elapsedSec: Int
  ) {
    guard let activity = activities[taskId] else { return }
    let state = DownloadActivityAttributes.DownloadState(
      progress: progress, speedMbps: speedMbps, done: done, total: total,
      status: status, elapsedSec: elapsedSec)
    Task {
      await activity.update(.init(state: state, staleDate: nil))
    }
  }

  func end(taskId: String) {
    guard let activity = activities.removeValue(forKey: taskId) else { return }
    Task {
      await activity.end(nil, dismissalPolicy: .immediate)
      NSLog("[LiveActivity] Ended for task \(taskId)")
    }
  }
}
