import Accelerate
import ExpoModulesCore
import AVFoundation

// ---------------------------------------------------------------------------
// Expo Module Definition
// ---------------------------------------------------------------------------

public class LocalTtsModule: Module, @unchecked Sendable {
  private let synthQueue = DispatchQueue(label: "expo.modules.localtts.synth")
  /// System TTS path (not the app session) avoids the spoken-audio accessibility graph
  /// that degrades neural / premium voices on real devices.
  private var synthesizer: AVSpeechSynthesizer = {
    let synth = AVSpeechSynthesizer()
    synth.usesApplicationAudioSession = false
    return synth
  }()
  private var speakDelegate: SpeechDelegate?
  /// Keeps the file synthesizer alive for the duration of `write(_:toBufferCallback:)`.
  /// Cleared on completion so the callback can use `[weak fileSynthesizer]` safely.
  private var activeFileSynthesizer: AVSpeechSynthesizer?

  public func definition() -> ModuleDefinition {
    Name("LocalTtsModule")

    Events(
      "onSpeechStart",
      "onSpeechDone",
      "onSpeechError",
      "onSpeechProgress"
    )

    // ----- speak -----
    AsyncFunction("speak") { (options: SpeakOptions, promise: Promise) in
      self.synthQueue.async {
        self.configureAudioSessionIfNeeded()

        // Cancel any in-flight utterance so its delegate can settle before we replace it.
        if self.synthesizer.isSpeaking {
          self.synthesizer.stopSpeaking(at: .immediate)
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
          onFinish: { [weak self] in
            self?.sendEvent("onSpeechDone", [:])
            promise.resolve(nil)
          },
          onError: { [weak self] message in
            self?.sendEvent("onSpeechError", ["message": message])
            promise.reject("ERR_TTS_SPEAK", message)
          }
        )
        self.speakDelegate = delegate
        self.synthesizer.delegate = delegate
        self.synthesizer.speak(utterance)
      }
    }

    // ----- synthesizeToFile -----
    AsyncFunction("synthesizeToFile") { (options: SynthesizeOptions, promise: Promise) in
      self.synthQueue.async {
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
            "synthesizeToFile requires a .wav filePath; AVAudioFile selects the container from the extension"
          )
          return
        }

        self.configureAudioSessionIfNeeded()

        let utterance = self.buildUtterance(options)

        // Ensure parent directory exists; overwrite any prior file at this path.
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: fileURL)

        let sink = Int16MonoWavSink(fileURL: fileURL)
        var writeError: Error?
        var didSettle = false
        let settleLock = NSLock()

        func settle(_ body: () -> Void) {
          settleLock.lock()
          defer { settleLock.unlock() }
          guard !didSettle else { return }
          didSettle = true
          body()
        }

        let fileSynthesizer = AVSpeechSynthesizer()
        fileSynthesizer.usesApplicationAudioSession = false
        // Module-owned strong ref keeps the synthesizer alive while the callback
        // only holds `[weak fileSynthesizer]` (no synthesizer ↔ callback cycle).
        self.activeFileSynthesizer = fileSynthesizer

        // Block this serial queue until synthesis finishes so concurrent
        // synthesizeToFile calls cannot interleave PCM writes / file headers.
        let done = DispatchSemaphore(value: 0)

        func failAndStop(_ error: Error) {
          // Settle immediately: stopSpeaking does not always deliver a terminal
          // buffer on every iOS version, and we must not block the synth queue.
          writeError = error
          settle {
            promise.reject("ERR_TTS_FILE_WRITE", error.localizedDescription)
            self.activeFileSynthesizer = nil
          }
          fileSynthesizer.stopSpeaking(at: .immediate)
          done.signal()
        }

        fileSynthesizer.write(utterance) { [weak self, weak fileSynthesizer] buffer in
          guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
          _ = fileSynthesizer // intentional weak capture (module retains via activeFileSynthesizer)

          // Ignore further buffers after the first hard failure.
          if writeError != nil {
            return
          }

          // iOS ≤16 ends with frameLength == 0. iOS 17+ Float32 paths often end
          // with a trailing buffer of frameLength == 1 (silent). Treat both as done.
          let isTerminalBuffer: Bool
          if pcmBuffer.format.commonFormat == .pcmFormatFloat32 {
            isTerminalBuffer = pcmBuffer.frameLength <= 1
          } else {
            isTerminalBuffer = pcmBuffer.frameLength == 0
          }

          if isTerminalBuffer {
            settle {
              if !sink.didWriteAudio {
                promise.reject(
                  "ERR_TTS_FILE_EMPTY",
                  "synthesizeToFile produced no audio buffers"
                )
              } else {
                promise.resolve(nil)
              }
              self?.activeFileSynthesizer = nil
            }
            done.signal()
            return
          }

          autoreleasepool {
            do {
              try sink.write(pcmBuffer)
            } catch {
              failAndStop(error)
            }
          }
        }

        if done.wait(timeout: .now() + 600) == .timedOut {
          settle {
            self.activeFileSynthesizer?.stopSpeaking(at: .immediate)
            self.activeFileSynthesizer = nil
            promise.reject("ERR_TTS_FILE_TIMEOUT", "synthesizeToFile timed out after 600s")
          }
        }
      }
    }

    // ----- getVoices -----
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

    // ----- stop -----
    Function("stop") {
      self.synthesizer.stopSpeaking(at: .immediate)
      // Also cancel in-flight file synthesis (write(_:toBufferCallback:)).
      self.activeFileSynthesizer?.stopSpeaking(at: .immediate)
    }

    // ----- isSpeaking -----
    Function("isSpeaking") { () -> Bool in
      self.synthesizer.isSpeaking
    }
  }

  // MARK: - Helpers

  private func configureAudioSessionIfNeeded() {
    do {
      let audioSession = AVAudioSession.sharedInstance()
      // .playback + .default: play in silent mode without the .spokenAudio accessibility
      // EQ/NR graph that makes neural voices sound robotic on real devices.
      // Synthesizers use usesApplicationAudioSession = false so speech still rides the
      // system TTS path (matching Settings previews) while this session stays available
      // for other app audio.
      try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
      try audioSession.setPreferredSampleRate(44_100)
      try audioSession.setActive(true)
    } catch {
      print("[LocalTtsModule] AudioSession configuration warning: \(error.localizedDescription)")
    }
  }

  /// Maps Apple quality + identifier footprint to the labels the JS layer buckets on.
  /// `super-compact` identifiers are the highest-quality on-device neural voices and
  /// often report as `.default` in the API enum — surface them as premium.
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
    // Rate: map user 1.0 (normal) to AVSpeechUtteranceDefaultSpeechRate, then
    // clamp into Apple's documented min/max speech-rate range.
    let scaledRate = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
    utterance.rate = min(
      AVSpeechUtteranceMaximumSpeechRate,
      max(AVSpeechUtteranceMinimumSpeechRate, scaledRate)
    )
    // pitchMultiplier is documented as roughly 0.5...2.0
    utterance.pitchMultiplier = min(2.0, max(0.5, Float(pitch)))
    // Micro-pause between queued speak() utterances (not meaningful for write()).
    utterance.postUtteranceDelay = 0.12

    // Priority 1: explicit voice identifier
    if !voice.isEmpty {
      if let foundVoice = AVSpeechSynthesisVoice(identifier: voice) {
        utterance.voice = foundVoice
        return utterance
      }
      print("[LocalTtsModule] Specified voice identifier '\(voice)' not found, attempting language fallback.")
    }

    // Priority 2: best installed voice for language
    // (super-compact > premium > enhanced > default)
    if !language.isEmpty {
      utterance.voice = bestVoice(forLanguage: language)
    }

    return utterance
  }

  /// Picks the highest-quality installed voice matching `language` (BCP-47).
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
    // Super-compact neural footprints outrank Apple's quality enum tiers.
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
// Streaming Int16 mono WAV writer
// ---------------------------------------------------------------------------

/// Streams AVSpeech PCM chunks to a `.wav` file as interleaved Int16 mono.
/// Reuses output format + scratch buffers across callbacks to avoid per-chunk alloc churn.
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
  private var converter: AVAudioConverter?
  private var converterSourceFormatKey: String?
  private(set) var didWriteAudio = false

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  func write(_ buffer: AVAudioPCMBuffer) throws {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return }

    if outFormat == nil {
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
      // Path extension is validated as .wav by the caller; settings are Linear PCM.
      audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
    }

    guard let outFormat, let audioFile else {
      throw SinkError.invalidFormat
    }

    // Zero-copy: already Int16 mono at the locked sample rate.
    if buffer.format.commonFormat == .pcmFormatInt16,
      buffer.format.channelCount == 1,
      buffer.format.sampleRate == outFormat.sampleRate
    {
      try audioFile.write(from: buffer)
      didWriteAudio = true
      return
    }

    let out = try ensureScratch(capacity: frames, format: outFormat)
    out.frameLength = AVAudioFrameCount(frames)
    try fillInt16Mono(from: buffer, into: out, format: outFormat)
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

  private func fillInt16Mono(
    from buffer: AVAudioPCMBuffer,
    into out: AVAudioPCMBuffer,
    format outFormat: AVAudioFormat
  ) throws {
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    guard frames > 0, channels > 0, let dst = out.int16ChannelData?[0] else {
      throw SinkError.convertFailed
    }

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
          dst[i] = Int16((clipped * Float(Int16.max)).rounded())
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

    // Uncommon formats (e.g. Int32): reuse one AVAudioConverter per source format.
    let sourceKey =
      "\(buffer.format.commonFormat.rawValue)-\(buffer.format.sampleRate)-\(buffer.format.channelCount)-\(buffer.format.isInterleaved)"
    if converter == nil || converterSourceFormatKey != sourceKey {
      guard let newConverter = AVAudioConverter(from: buffer.format, to: outFormat) else {
        throw SinkError.convertFailed
      }
      converter = newConverter
      converterSourceFormatKey = sourceKey
    }
    guard let converter else { throw SinkError.convertFailed }

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

  /// Clip → scale → quantize using Accelerate; temp floats live on the stack when possible.
  private static func convertMonoFloat32ToInt16(
    src: UnsafePointer<Float>,
    dst: UnsafeMutablePointer<Int16>,
    frames: Int
  ) {
    let n = vDSP_Length(frames)
    withUnsafeTemporaryAllocation(of: Float.self, capacity: frames) { temp in
      guard let tempBase = temp.baseAddress else { return }
      var lo: Float = -1
      var hi: Float = 1
      vDSP_vclip(src, 1, &lo, &hi, tempBase, 1, n)
      var scale = Float(Int16.max)
      vDSP_vsmul(tempBase, 1, &scale, tempBase, 1, n)
      // Quantize with rounding. Prefer a typed loop over Accelerate overlays —
      // vDSP.convert Float→Int16 is not consistently resolvable across SDKs, and
      // vDSP_vfixq writes Int32 (wrong width for our Int16 CAF path).
      for i in 0..<frames {
        dst[i] = Int16(clamping: Int(tempBase[i].rounded(.toNearestOrAwayFromZero)))
      }
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
// AVSpeechSynthesizerDelegate for speech lifecycle events
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
