import AVFoundation
import AVKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let backgroundKeepAlive = BackgroundKeepAliveController()
  private let pictureInPicture = NativePictureInPictureController()
  private var backgroundChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    MobileFfiForceLink()
    configureAudioSession()
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    installBackgroundChannel()
    DispatchQueue.main.async { [weak self] in
      self?.installBackgroundChannel()
    }
    return launched
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    installBackgroundChannel()
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
}

private final class BackgroundKeepAliveController {
  private var audioPlayer: AVAudioPlayer?
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var enabled = false

  func setEnabled(_ shouldEnable: Bool) throws {
    if shouldEnable {
      try start()
    } else {
      stop()
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
        domain: "IPTVGrabBackgroundKeepAlive",
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
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "iptvgrab-downloads") {
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

// Uses AVPlayerViewController (the officially recommended PiP API) rather than
// the raw AVPlayerLayer trick, which has become increasingly restricted in
// newer iOS versions. The view controller is embedded as a tiny invisible child
// of the Flutter view controller — required to be in the window hierarchy for
// PiP to work.
private final class NativePictureInPictureController: NSObject, AVPlayerViewControllerDelegate {
  private var player: AVPlayer?
  private var playerViewController: AVPlayerViewController?
  private var itemStatusObservation: NSKeyValueObservation?
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

    let playerVC = AVPlayerViewController()
    playerVC.player = player
    playerVC.allowsPictureInPicturePlayback = true
    playerVC.showsPlaybackControls = false
    playerVC.delegate = self
    if #available(iOS 14.2, *) {
      playerVC.canStartPictureInPictureAutomaticallyFromInline = true
    }

    // Embed as a 2×2 invisible child — the view must be in the window
    // hierarchy or startPictureInPicture() will be ignored by the system.
    hostViewController.addChild(playerVC)
    playerVC.view.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
    playerVC.view.alpha = 0.01
    hostViewController.view.addSubview(playerVC.view)
    playerVC.didMove(toParent: hostViewController)

    self.player = player
    self.playerViewController = playerVC
    self.pendingResult = result

    player.play()

    // Wait for the player item to become ready before triggering PiP.
    // Calling startPictureInPicture() on an AVPlayerViewController whose
    // item hasn't loaded yet is silently ignored on iOS 15+.
    itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
      guard let self else { return }
      switch item.status {
      case .readyToPlay:
        self.itemStatusObservation?.invalidate()
        self.itemStatusObservation = nil
        NSLog("[PiP] AVPlayerItem readyToPlay — calling startPictureInPicture()")
        DispatchQueue.main.async { self.launchPiP() }
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

  private func launchPiP() {
    guard let playerVC = playerViewController else {
      finishWithResult(false)
      return
    }

    if #available(iOS 15.0, *) {
      playerVC.startPictureInPicture()
      // Result is delivered via AVPlayerViewControllerDelegate below.
      // Add a safety timeout in case the delegate never fires.
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
        guard let self, self.pendingResult != nil else { return }
        NSLog("[PiP] startPictureInPicture() delegate timeout")
        self.finishWithResult(false)
        self.cleanup()
      }
    } else {
      // iOS 14: startPictureInPicture() isn't available on AVPlayerViewController.
      NSLog("[PiP] iOS < 15: AVPlayerViewController.startPictureInPicture() unavailable")
      finishWithResult(false)
      cleanup()
    }
  }

  // MARK: - AVPlayerViewControllerDelegate

  func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
    NSLog("[PiP] willStartPictureInPicture")
    finishWithResult(true)
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    NSLog("[PiP] failedToStartPictureInPictureWithError: \(error)")
    finishWithResult(false)
    cleanup()
  }

  func playerViewControllerDidStopPictureInPicture(
    _ playerViewController: AVPlayerViewController
  ) {
    NSLog("[PiP] didStopPictureInPicture")
    cleanup()
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
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
    pendingResult = nil
    cleanup()
  }

  private func cleanup() {
    itemStatusObservation?.invalidate()
    itemStatusObservation = nil
    player?.pause()
    player = nil
    if let playerVC = playerViewController {
      // Nil delegate FIRST to prevent re-entrant cleanup via
      // playerViewControllerDidStopPictureInPicture callback.
      playerVC.delegate = nil
      if #available(iOS 15.0, *) {
        playerVC.stopPictureInPicture()
      }
      playerVC.willMove(toParent: nil)
      playerVC.view.removeFromSuperview()
      playerVC.removeFromParent()
    }
    playerViewController = nil
  }
}
