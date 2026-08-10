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

        self.configureAudioSessionIfNeeded()

        let utterance = self.buildUtterance(options)
        let fileURL = URL(fileURLWithPath: options.filePath)

        // Ensure parent directory exists; overwrite any prior file at this path.
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: fileURL)

        var audioFile: AVAudioFile?
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

        fileSynthesizer.write(utterance) { [weak self, weak fileSynthesizer] buffer in
          guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
          _ = fileSynthesizer // intentional weak capture (module retains via activeFileSynthesizer)

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
              if let err = writeError {
                promise.reject("ERR_TTS_FILE_WRITE", err.localizedDescription)
              } else if audioFile == nil {
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
              // Always write Int16 mono WAV. AVSpeech buffers are often Float32
              // CAF-oriented formats that miniaudio (and many players) cannot decode.
              guard let wavBuffer = Self.convertToInt16MonoWavBuffer(pcmBuffer) else {
                writeError = NSError(
                  domain: "LocalTts",
                  code: -1,
                  userInfo: [
                    NSLocalizedDescriptionKey: "Failed to convert TTS PCM buffer to Int16 WAV",
                  ]
                )
                return
              }

              if audioFile == nil {
                audioFile = try AVAudioFile(
                  forWriting: fileURL,
                  settings: wavBuffer.format.settings
                )
              }
              try audioFile?.write(from: wavBuffer)
            } catch {
              writeError = error
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

  /// Converts an AVSpeech PCM buffer to interleaved Int16 mono for WAV output.
  private static func convertToInt16MonoWavBuffer(
    _ buffer: AVAudioPCMBuffer
  ) -> AVAudioPCMBuffer? {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return nil }

    guard
      let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: buffer.format.sampleRate,
        channels: 1,
        interleaved: true
      ),
      let out = AVAudioPCMBuffer(
        pcmFormat: outFormat,
        frameCapacity: AVAudioFrameCount(frames)
      ),
      let dst = out.int16ChannelData?[0]
    else {
      return nil
    }

    out.frameLength = AVAudioFrameCount(frames)
    let channels = Int(buffer.format.channelCount)
    guard channels > 0 else { return nil }

    if buffer.format.commonFormat == .pcmFormatFloat32,
      let src = buffer.floatChannelData
    {
      for i in 0..<frames {
        var sample: Float = 0
        for ch in 0..<channels {
          sample += src[ch][i]
        }
        if channels > 1 {
          sample /= Float(channels)
        }
        let clipped = max(-1.0 as Float, min(1.0 as Float, sample))
        dst[i] = Int16((clipped * Float(Int16.max)).rounded())
      }
      return out
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
      return out
    }

    // Fallback for uncommon formats (e.g. Int32): convert via AVAudioConverter.
    guard let converter = AVAudioConverter(from: buffer.format, to: outFormat) else {
      return nil
    }
    var converted = false
    var convertError: NSError?
    let status = converter.convert(to: out, error: &convertError) { _, outStatus in
      if converted {
        outStatus.pointee = .noDataNow
        return nil
      }
      converted = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard convertError == nil, status != .error else { return nil }
    return out
  }

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
