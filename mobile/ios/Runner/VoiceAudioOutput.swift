import AVFoundation
import Flutter
import UIKit

@MainActor
final class VoiceAudioOutput:
  NSObject,
  @preconcurrency AVAudioPlayerDelegate,
  @preconcurrency AVSpeechSynthesizerDelegate
{
  private let channel: FlutterMethodChannel
  private let speechSynthesizer: AVSpeechSynthesizer
  private var player: AVAudioPlayer?
  private var activeUtterance: AVSpeechUtterance?
  private var previousAudioSessionState: AudioSessionState?
  private var observers: [NSObjectProtocol] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "buzz/voice_audio",
      binaryMessenger: messenger
    )
    speechSynthesizer = AVSpeechSynthesizer()
    super.init()
    speechSynthesizer.delegate = self
    speechSynthesizer.usesApplicationAudioSession = true
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
    case "speakSystem":
      guard let text = call.arguments as? String, !text.isEmpty else {
        result(FlutterError(code: "invalid_arguments", message: "Expected speech text.", details: nil))
        return
      }
      do {
        try speakSystem(text)
        result(nil)
      } catch {
        result(FlutterError(code: "speech_failed", message: error.localizedDescription, details: nil))
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
    try activateAudioSession()
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
      channel.invokeMethod("started", arguments: nil)
    } catch {
      restoreAudioSession()
      throw error
    }
  }

  private func speakSystem(_ text: String) throws {
    stop(deactivate: false)
    try activateAudioSession()
    let utterance = Self.systemUtterance(text)
    activeUtterance = utterance
    speechSynthesizer.speak(utterance)
  }

  static func configureAudioSession(_ session: AVAudioSession) throws {
    try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
  }

  static func systemUtterance(_ text: String) -> AVSpeechUtterance {
    let utterance = AVSpeechUtterance(string: text)
    utterance.prefersAssistiveTechnologySettings = true
    return utterance
  }

  private func activateAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    if previousAudioSessionState == nil {
      previousAudioSessionState = AudioSessionState(session: session)
    }
    do {
      try Self.configureAudioSession(session)
      try session.setActive(true)
    } catch {
      restoreAudioSession()
      throw error
    }
  }

  private func stop(deactivate: Bool) {
    activeUtterance = nil
    if speechSynthesizer.isSpeaking {
      speechSynthesizer.stopSpeaking(at: .immediate)
    }
    player?.delegate = nil
    player?.stop()
    player = nil
    if deactivate {
      restoreAudioSession()
    }
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    guard self.player === player else { return }
    self.player = nil
    restoreAudioSession()
    channel.invokeMethod(flag ? "completed" : "error", arguments: nil)
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    guard self.player === player else { return }
    self.player = nil
    restoreAudioSession()
    channel.invokeMethod("error", arguments: error?.localizedDescription)
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    guard activeUtterance === utterance else { return }
    activeUtterance = nil
    restoreAudioSession()
    channel.invokeMethod("completed", arguments: nil)
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    guard activeUtterance === utterance else { return }
    activeUtterance = nil
    restoreAudioSession()
    channel.invokeMethod("error", arguments: "System speech was cancelled.")
  }

  private func restoreAudioSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    if let previousAudioSessionState {
      try? session.setCategory(
        previousAudioSessionState.category,
        mode: previousAudioSessionState.mode,
        options: previousAudioSessionState.options
      )
      self.previousAudioSessionState = nil
    }
  }

  private func observeAudioLifecycle() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        Task { @MainActor [weak self] in
          guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: rawType) == .began
          else { return }
          self?.interrupt(with: "interrupted")
        }
      }
    )
    observers.append(
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        Task { @MainActor [weak self] in
          guard
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
          else { return }
          self?.interrupt(with: "routeLost")
        }
      }
    )
    observers.append(
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.interrupt(with: "backgrounded", requirePlayback: false)
        }
      }
    )
    observers.append(
      center.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.channel.invokeMethod("foregrounded", arguments: nil)
        }
      }
    )
    observers.append(
      center.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.channel.invokeMethod("resourcePressure", arguments: nil)
        }
      }
    )
  }

  private func interrupt(with event: String, requirePlayback: Bool = true) {
    if requirePlayback && player == nil && activeUtterance == nil { return }
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

private struct AudioSessionState {
  let category: AVAudioSession.Category
  let mode: AVAudioSession.Mode
  let options: AVAudioSession.CategoryOptions

  init(session: AVAudioSession) {
    category = session.category
    mode = session.mode
    options = session.categoryOptions
  }
}

private extension Data {
  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}
