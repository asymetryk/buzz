import AVFoundation
import Flutter
import UIKit

final class VoiceAudioOutput: NSObject, AVAudioPlayerDelegate {
  private let channel: FlutterMethodChannel
  private var player: AVAudioPlayer?
  private var observers: [NSObjectProtocol] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "buzz/voice_audio",
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    observeAudioLifecycle()
  }

  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "play":
      guard
        let arguments = call.arguments as? [String: Any],
        let typedData = arguments["pcm"] as? FlutterStandardTypedData,
        let sampleRate = arguments["sampleRate"] as? Int
      else {
        result(FlutterError(code: "invalid_arguments", message: "Expected PCM and sample rate.", details: nil))
        return
      }
      do {
        try play(pcm: typedData.data, sampleRate: sampleRate)
        result(nil)
      } catch {
        result(FlutterError(code: "playback_failed", message: error.localizedDescription, details: nil))
      }
    case "stop":
      stop(deactivate: true)
      result(nil)
    case "availableCapacity":
      guard let path = call.arguments as? String else {
        result(FlutterError(code: "invalid_arguments", message: "Expected a storage path.", details: nil))
        return
      }
      do {
        let values = try URL(fileURLWithPath: path).resourceValues(
          forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        result(values.volumeAvailableCapacityForImportantUsage ?? 0)
      } catch {
        result(FlutterError(code: "storage_failed", message: error.localizedDescription, details: nil))
      }
    case "excludeFromBackup":
      guard let path = call.arguments as? String else {
        result(FlutterError(code: "invalid_arguments", message: "Expected a storage path.", details: nil))
        return
      }
      do {
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        result(nil)
      } catch {
        result(FlutterError(code: "storage_failed", message: error.localizedDescription, details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func play(pcm: Data, sampleRate: Int) throws {
    stop(deactivate: false)
    let session = AVAudioSession.sharedInstance()
    try Self.configureAudioSession(session)
    try session.setActive(true)
    do {
      let nextPlayer = try AVAudioPlayer(data: Self.waveData(pcm: pcm, sampleRate: sampleRate))
      nextPlayer.delegate = self
      nextPlayer.prepareToPlay()
      guard nextPlayer.play() else {
        throw NSError(
          domain: "BuzzVoice",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Unable to start voice playback."]
        )
      }
      player = nextPlayer
    } catch {
      try? session.setActive(false, options: [.notifyOthersOnDeactivation])
      throw error
    }
  }

  static func configureAudioSession(_ session: AVAudioSession) throws {
    try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
  }

  private func stop(deactivate: Bool) {
    player?.stop()
    player = nil
    if deactivate {
      try? AVAudioSession.sharedInstance().setActive(
        false,
        options: [.notifyOthersOnDeactivation]
      )
    }
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    guard self.player === player else { return }
    self.player = nil
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: [.notifyOthersOnDeactivation]
    )
    channel.invokeMethod(flag ? "completed" : "error", arguments: nil)
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    guard self.player === player else { return }
    self.player = nil
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: [.notifyOthersOnDeactivation]
    )
    channel.invokeMethod("error", arguments: error?.localizedDescription)
  }

  private func observeAudioLifecycle() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard
          let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: rawType) == .began
        else { return }
        self?.interrupt(with: "interrupted")
      }
    )
    observers.append(
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard
          let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
        else { return }
        self?.interrupt(with: "routeLost")
      }
    )
    observers.append(
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.interrupt(with: "backgrounded", requirePlayback: false)
      }
    )
  }

  private func interrupt(with event: String, requirePlayback: Bool = true) {
    if requirePlayback && player == nil { return }
    stop(deactivate: true)
    channel.invokeMethod(event, arguments: nil)
  }

  private static func waveData(pcm: Data, sampleRate: Int) -> Data {
    var output = Data()
    output.append(contentsOf: "RIFF".utf8)
    output.appendLittleEndian(UInt32(pcm.count + 36))
    output.append(contentsOf: "WAVEfmt ".utf8)
    output.appendLittleEndian(UInt32(16))
    output.appendLittleEndian(UInt16(1))
    output.appendLittleEndian(UInt16(1))
    output.appendLittleEndian(UInt32(sampleRate))
    output.appendLittleEndian(UInt32(sampleRate * 2))
    output.appendLittleEndian(UInt16(2))
    output.appendLittleEndian(UInt16(16))
    output.append(contentsOf: "data".utf8)
    output.appendLittleEndian(UInt32(pcm.count))
    output.append(pcm)
    return output
  }
}

private extension Data {
  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}
