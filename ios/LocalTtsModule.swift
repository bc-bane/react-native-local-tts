import ExpoModulesCore
import AVFoundation

// ---------------------------------------------------------------------------
// Expo Module Definition
//
// Threading contract (Expo Modules + AVSpeechSynthesizer):
//
// 1. Expo `AsyncFunction` runs on `expo.modules.AsyncFunctionQueue` (serial).
//    Return immediately; resolve the Promise later from a callback.
//
// 2. `AVSpeechSynthesizer.write` delivers buffers via the main run loop.
//    Calling `write` from a background thread can internally `dispatch_sync`
//    to main and then wait for those same main-queue buffers → permanent
//    deadlock / frozen UI. Always start `write` with `DispatchQueue.main.async`
//    and never semaphore-wait around it.
//
// 3. Creating/touching `AVSpeechSynthesizer` / voice lookup triggers XPC and
//    can stall the calling thread. Prefer a long-lived file synthesizer and
//    avoid doing that work on AsyncFunctionQueue.
//
// 4. Offline `write` keeps default `usesApplicationAudioSession == true`.
//    `false` is only for live `speak()` preview quality.
//
// 5. `AVAudioFile` must use the buffer's own commonFormat + isInterleaved.
// ---------------------------------------------------------------------------

public class LocalTtsModule: Module, @unchecked Sendable {
  private let speakQueue = DispatchQueue(label: "expo.modules.localtts.speak")
  private let fileJobQueue = DispatchQueue(label: "expo.modules.localtts.filejobs")

  private var speakSynthesizer: AVSpeechSynthesizer = {
    let synth = AVSpeechSynthesizer()
    synth.usesApplicationAudioSession = false
    return synth
  }()
  private var speakDelegate: SpeechDelegate?

  /// Long-lived offline synthesizer. Created lazily on a utility queue to avoid
  /// first-use XPC stalls on AsyncFunctionQueue / main during conversion.
  private var fileSynthesizer: AVSpeechSynthesizer?
  private let fileSynthesizerLock = NSLock()

  private var fileJobRunning = false
  private var pendingFileJobs: [(SynthesizeOptions, Promise)] = []

  public func definition() -> ModuleDefinition {
    Name("LocalTtsModule")

    OnCreate {
      // Pre-warm voice catalog + file synthesizer off the hot path.
      DispatchQueue.global(qos: .utility).async { [weak self] in
        _ = AVSpeechSynthesisVoice.speechVoices()
        self?.ensureFileSynthesizer()
      }
    }

    Events(
      "onSpeechStart",
      "onSpeechDone",
      "onSpeechError",
      "onSpeechProgress"
    )

    AsyncFunction("speak") { (options: SpeakOptions, promise: Promise) in
      self.speakQueue.async {
        self.configureSpeakAudioSession()

        if self.speakSynthesizer.isSpeaking {
          self.speakSynthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = self.buildUtterance(options)
        let delegate = SpeechDelegate(
          onStart: { [weak self] in
            self?.sendEvent("onSpeechStart", [:])
          },
          onProgress: { [weak self] charIndex, charLength in
            self?.sendEvent("onSpeechProgress", [
              "charIndex": charIndex,
              "charLength": charLength
            ])
          },
          onFinish: {
            promise.resolve(nil)
          },
          onError: { [weak self] message in
            self?.sendEvent("onSpeechError", ["message": message])
            promise.reject("ERR_TTS_SPEAK", message)
          }
        )
        self.speakDelegate = delegate
        self.speakSynthesizer.delegate = delegate
        self.speakSynthesizer.speak(utterance)
      }
    }

    AsyncFunction("synthesizeToFile") { (options: SynthesizeOptions, promise: Promise) in
      guard #available(iOS 13.0, *) else {
        promise.reject("ERR_TTS_UNSUPPORTED", "synthesizeToFile requires iOS 13+")
        return
      }

      if options.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        promise.reject("ERR_TTS_FILE", "synthesizeToFile requires non-empty text")
        return
      }

      let fileURL = URL(fileURLWithPath: options.filePath)
      guard fileURL.pathExtension.lowercased() == "wav" else {
        promise.reject(
          "ERR_TTS_FILE_PATH",
          "synthesizeToFile requires a .wav filePath"
        )
        return
      }

      // Return immediately from AsyncFunctionQueue — never block it.
      self.fileJobQueue.async {
        self.pendingFileJobs.append((options, promise))
        self.startNextFileJobIfNeeded()
      }
    }

    AsyncFunction("getVoices") { () -> [[String: Any]] in
      AVSpeechSynthesisVoice.speechVoices().map { voice in
        [
          "identifier": voice.identifier,
          "name": voice.name,
          "language": voice.language,
          "quality": self.reportedQuality(for: voice)
        ]
      }
    }

    Function("stop") {
      self.speakSynthesizer.stopSpeaking(at: .immediate)
      self.fileSynthesizerLock.lock()
      self.fileSynthesizer?.stopSpeaking(at: .immediate)
      self.fileSynthesizerLock.unlock()
    }

    Function("isSpeaking") { () -> Bool in
      self.speakSynthesizer.isSpeaking
    }
  }

  // MARK: - File synthesis

  private func ensureFileSynthesizer() -> AVSpeechSynthesizer {
    fileSynthesizerLock.lock()
    defer { fileSynthesizerLock.unlock() }
    if let fileSynthesizer {
      return fileSynthesizer
    }
    let synth = AVSpeechSynthesizer()
    // Default usesApplicationAudioSession (= true) required for write(_:).
    fileSynthesizer = synth
    return synth
  }

  private func startNextFileJobIfNeeded() {
    guard !fileJobRunning, !pendingFileJobs.isEmpty else { return }
    fileJobRunning = true
    let (options, promise) = pendingFileJobs.removeFirst()

    // Prepare file URL / utterance off main (may touch voice XPC).
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }

      let fileURL = URL(fileURLWithPath: options.filePath)
      let dir = fileURL.deletingLastPathComponent()
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: fileURL)

      let utterance = self.buildUtterance(options)
      let synth = self.ensureFileSynthesizer()

      print(
        "[LocalTtsModule] synthesizeToFile enqueue chars=\(options.text.count) voice=\(options.voice) file=\(fileURL.lastPathComponent)"
      )

      // CRITICAL: start write on the main queue asynchronously. Do not call write
      // from a background thread (deadlock risk with main-run-loop buffer delivery).
      DispatchQueue.main.async {
        self.beginWriteOnMain(
          synthesizer: synth,
          utterance: utterance,
          fileURL: fileURL,
          promise: promise
        )
      }
    }
  }

  private func finishFileJob() {
    fileJobQueue.async { [weak self] in
      guard let self else { return }
      self.fileJobRunning = false
      self.startNextFileJobIfNeeded()
    }
  }

  /// Must be called on the main queue.
  private func beginWriteOnMain(
    synthesizer: AVSpeechSynthesizer,
    utterance: AVSpeechUtterance,
    fileURL: URL,
    promise: Promise
  ) {
    assert(Thread.isMainThread)

    configureFileAudioSession()

    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }

    var writeError: Error?
    var didSettle = false
    let settleLock = NSLock()

    func settle(_ body: () -> Void) {
      settleLock.lock()
      defer { settleLock.unlock() }
      guard !didSettle else { return }
      didSettle = true
      body()
      self.finishFileJob()
    }

    let timeoutWork = DispatchWorkItem {
      print("[LocalTtsModule] synthesizeToFile TIMEOUT \(fileURL.lastPathComponent)")
      settle {
        synthesizer.stopSpeaking(at: .immediate)
        promise.reject("ERR_TTS_FILE_TIMEOUT", "synthesizeToFile timed out after 120s")
      }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeoutWork)

    print("[LocalTtsModule] synthesizeToFile START on main \(fileURL.lastPathComponent)")

    // miniaudio (react-native-audio-api) cannot decode Float32 WAV that AVSpeech
    // often emits on modern iOS — normalize to Int16 mono PCM WAV.
    let sink = Int16MonoWavSink(fileURL: fileURL)

    // Returns immediately; main run loop delivers buffers between turns.
    synthesizer.write(utterance) { buffer in
      guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }

      if writeError != nil {
        return
      }

      let isTerminalBuffer: Bool
      if pcmBuffer.format.commonFormat == .pcmFormatFloat32 {
        isTerminalBuffer = pcmBuffer.frameLength <= 1
      } else {
        isTerminalBuffer = pcmBuffer.frameLength == 0
      }

      if isTerminalBuffer {
        timeoutWork.cancel()
        // Finalize WAV header before JS decodeAudioData opens the path.
        sink.close()
        settle {
          if !sink.didWriteAudio {
            promise.reject(
              "ERR_TTS_FILE_EMPTY",
              "synthesizeToFile produced no audio buffers"
            )
          } else {
            print("[LocalTtsModule] synthesizeToFile OK \(fileURL.lastPathComponent)")
            promise.resolve(nil)
          }
        }
        return
      }

      do {
        try sink.write(pcmBuffer)
      } catch {
        writeError = error
        timeoutWork.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        sink.close()
        settle {
          promise.reject("ERR_TTS_FILE_WRITE", error.localizedDescription)
        }
      }
    }
  }

  // MARK: - Audio sessions

  private func configureSpeakAudioSession() {
    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
      try audioSession.setPreferredSampleRate(44_100)
      try audioSession.setActive(true)
    } catch {
      print("[LocalTtsModule] Speak AudioSession warning: \(error.localizedDescription)")
    }
  }

  private func configureFileAudioSession() {
    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
      try audioSession.setPreferredSampleRate(44_100)
      try audioSession.setActive(true)
    } catch {
      print("[LocalTtsModule] File AudioSession warning: \(error.localizedDescription)")
    }
  }

  // MARK: - Voices / utterances

  private func reportedQuality(for voice: AVSpeechSynthesisVoice) -> String {
    if voice.identifier.localizedCaseInsensitiveContains("super-compact") {
      return "premium"
    }
    if #available(iOS 16.0, *), voice.quality == .premium {
      return "premium"
    }
    if #available(iOS 9.0, *), voice.quality == .enhanced {
      return "enhanced"
    }
    return "default"
  }

  private func buildUtterance(_ options: SpeakOptions) -> AVSpeechUtterance {
    createUtterance(
      text: options.text,
      rate: options.rate,
      pitch: options.pitch,
      language: options.language,
      voice: options.voice
    )
  }

  private func buildUtterance(_ options: SynthesizeOptions) -> AVSpeechUtterance {
    createUtterance(
      text: options.text,
      rate: options.rate,
      pitch: options.pitch,
      language: options.language,
      voice: options.voice
    )
  }

  private func createUtterance(
    text: String,
    rate: Double,
    pitch: Double,
    language: String,
    voice: String
  ) -> AVSpeechUtterance {
    let utterance = AVSpeechUtterance(string: text)
    let scaledRate = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
    utterance.rate = min(
      AVSpeechUtteranceMaximumSpeechRate,
      max(AVSpeechUtteranceMinimumSpeechRate, scaledRate)
    )
    utterance.pitchMultiplier = min(2.0, max(0.5, Float(pitch)))
    utterance.postUtteranceDelay = 0.12

    if !voice.isEmpty {
      if let foundVoice = AVSpeechSynthesisVoice(identifier: voice) {
        utterance.voice = foundVoice
        return utterance
      }
      print("[LocalTtsModule] voice '\(voice)' not found, trying language fallback")
    }

    if !language.isEmpty {
      utterance.voice = bestVoice(forLanguage: language)
    }

    return utterance
  }

  private func bestVoice(forLanguage language: String) -> AVSpeechSynthesisVoice? {
    let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
      voice.language.caseInsensitiveCompare(language) == .orderedSame
        || voice.language.lowercased().hasPrefix(language.lowercased() + "-")
        || language.lowercased().hasPrefix(voice.language.lowercased())
    }

    if voices.isEmpty {
      return AVSpeechSynthesisVoice(language: language)
    }

    return voices.max { lhs, rhs in
      voiceQualityRank(lhs) < voiceQualityRank(rhs)
    }
  }

  private func voiceQualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
    if voice.identifier.localizedCaseInsensitiveContains("super-compact") {
      return 4
    }
    if #available(iOS 16.0, *) {
      if voice.quality == .premium { return 3 }
    }
    if #available(iOS 9.0, *) {
      if voice.quality == .enhanced { return 2 }
    }
    return 1
  }
}

// ---------------------------------------------------------------------------
// Int16 mono WAV sink (miniaudio-compatible)
// ---------------------------------------------------------------------------

/// Converts AVSpeech PCM buffers to Int16 mono non-interleaved WAV.
/// Float32 WAV from modern AVSpeech is rejected by miniaudio ("Failed to decode any frames").
private final class Int16MonoWavSink {
  enum SinkError: LocalizedError {
    case invalidFormat
    case convertFailed

    var errorDescription: String? {
      switch self {
      case .invalidFormat:
        return "Failed to create Int16 mono WAV format for TTS output"
      case .convertFailed:
        return "Failed to convert TTS PCM buffer to Int16 mono WAV"
      }
    }
  }

  private let fileURL: URL
  private var audioFile: AVAudioFile?
  private var outFormat: AVAudioFormat?
  private var scratch: AVAudioPCMBuffer?
  private(set) var didWriteAudio = false

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  /// Releases `AVAudioFile` so the WAV header/data size is finalized on disk.
  /// Must run before JS `decodeAudioData` opens the same path.
  func close() {
    audioFile = nil
    scratch = nil
  }

  func write(_ buffer: AVAudioPCMBuffer) throws {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return }

    if outFormat == nil {
      // Interleaved Int16 mono is the most widely supported WAV layout for miniaudio.
      guard
        let format = AVAudioFormat(
          commonFormat: .pcmFormatInt16,
          sampleRate: buffer.format.sampleRate,
          channels: 1,
          interleaved: true
        )
      else {
        throw SinkError.invalidFormat
      }
      outFormat = format
      audioFile = try AVAudioFile(
        forWriting: fileURL,
        settings: format.settings,
        commonFormat: .pcmFormatInt16,
        interleaved: true
      )
    }

    guard let outFormat, let audioFile else {
      throw SinkError.invalidFormat
    }

    let out = try ensureScratch(capacity: frames, format: outFormat)
    out.frameLength = AVAudioFrameCount(frames)
    try fillInt16Mono(from: buffer, into: out)
    try audioFile.write(from: out)
    didWriteAudio = true
  }

  private func ensureScratch(capacity: Int, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    if let scratch, Int(scratch.frameCapacity) >= capacity {
      return scratch
    }
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(capacity)
      )
    else {
      throw SinkError.invalidFormat
    }
    scratch = buffer
    return buffer
  }

  private func fillInt16Mono(from buffer: AVAudioPCMBuffer, into out: AVAudioPCMBuffer) throws {
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    guard frames > 0, channels > 0 else {
      throw SinkError.convertFailed
    }

    // Interleaved mono: channel data pointers are nil — use the AudioBufferList.
    guard let dstRaw = out.mutableAudioBufferList.pointee.mBuffers.mData else {
      throw SinkError.convertFailed
    }
    let dst = dstRaw.assumingMemoryBound(to: Int16.self)

    if buffer.format.commonFormat == .pcmFormatFloat32,
      let src = buffer.floatChannelData
    {
      if channels == 1 {
        Self.convertMonoFloat32ToInt16(src: src[0], dst: dst, frames: frames)
      } else {
        for i in 0..<frames {
          var sample: Float = 0
          for ch in 0..<channels {
            sample += src[ch][i]
          }
          sample /= Float(channels)
          let clipped = max(-1 as Float, min(1 as Float, sample))
          dst[i] = Int16(clamping: Int((clipped * Float(Int16.max)).rounded()))
        }
      }
      return
    }

    if buffer.format.commonFormat == .pcmFormatInt16,
      let src = buffer.int16ChannelData
    {
      if channels == 1 {
        memcpy(dst, src[0], frames * MemoryLayout<Int16>.size)
      } else {
        for i in 0..<frames {
          var sum = 0
          for ch in 0..<channels {
            sum += Int(src[ch][i])
          }
          dst[i] = Int16(sum / channels)
        }
      }
      return
    }

    // Interleaved source or uncommon formats.
    guard
      let converter = AVAudioConverter(from: buffer.format, to: out.format)
    else {
      throw SinkError.convertFailed
    }

    var provided = false
    var convertError: NSError?
    let status = converter.convert(to: out, error: &convertError) { _, outStatus in
      if provided {
        outStatus.pointee = .noDataNow
        return nil
      }
      provided = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard convertError == nil, status != .error else {
      throw SinkError.convertFailed
    }
  }

  private static func convertMonoFloat32ToInt16(
    src: UnsafePointer<Float>,
    dst: UnsafeMutablePointer<Int16>,
    frames: Int
  ) {
    for i in 0..<frames {
      let clipped = max(-1 as Float, min(1 as Float, src[i]))
      dst[i] = Int16(clamping: Int((clipped * Float(Int16.max)).rounded()))
    }
  }
}

// ---------------------------------------------------------------------------
// Options Records
// ---------------------------------------------------------------------------

private struct SpeakOptions: Record {
  @Field var text: String = ""
  @Field var rate: Double = 1.0
  @Field var pitch: Double = 1.0
  @Field var language: String = ""
  @Field var voice: String = ""
}

private struct SynthesizeOptions: Record {
  @Field var text: String = ""
  @Field var filePath: String = ""
  @Field var rate: Double = 1.0
  @Field var pitch: Double = 1.0
  @Field var language: String = ""
  @Field var voice: String = ""
}

// ---------------------------------------------------------------------------
// Live speak() delegate
// ---------------------------------------------------------------------------

private class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
  let onStart: () -> Void
  let onProgress: (Int, Int) -> Void
  let onFinish: () -> Void
  let onError: (String) -> Void

  init(
    onStart: @escaping () -> Void,
    onProgress: @escaping (Int, Int) -> Void,
    onFinish: @escaping () -> Void,
    onError: @escaping (String) -> Void
  ) {
    self.onStart = onStart
    self.onProgress = onProgress
    self.onFinish = onFinish
    self.onError = onError
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    onStart()
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    onFinish()
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    onFinish()
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    willSpeakRangeOfSpeechString characterRange: NSRange,
    utterance: AVSpeechUtterance
  ) {
    onProgress(characterRange.location, characterRange.length)
  }
}
