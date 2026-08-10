import ExpoModulesCore
import AVFoundation

// ---------------------------------------------------------------------------
// Expo Module Definition
// ---------------------------------------------------------------------------

public class LocalTtsModule: Module, @unchecked Sendable {
  private let synthQueue = DispatchQueue(label: "expo.modules.localtts.synth")
  private var synthesizer = AVSpeechSynthesizer()
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

        // Ensure parent directory exists
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

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
        // Module-owned strong ref keeps the synthesizer alive while the callback
        // only holds `[weak fileSynthesizer]` (no synthesizer ↔ callback cycle).
        self.activeFileSynthesizer = fileSynthesizer

        // Block this serial queue until synthesis finishes so concurrent
        // synthesizeToFile calls cannot interleave PCM writes / file headers.
        let done = DispatchSemaphore(value: 0)

        fileSynthesizer.write(utterance) { [weak self, weak fileSynthesizer] buffer in
          guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
          _ = fileSynthesizer // intentional weak capture (module retains via activeFileSynthesizer)

          if pcmBuffer.frameLength == 0 {
            settle {
              if let err = writeError {
                promise.reject("ERR_TTS_FILE_WRITE", err.localizedDescription)
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
              if audioFile == nil {
                audioFile = try AVAudioFile(
                  forWriting: fileURL,
                  settings: pcmBuffer.format.settings,
                  commonFormat: pcmBuffer.format.commonFormat,
                  interleaved: pcmBuffer.format.isInterleaved
                )
              }
              try audioFile?.write(from: pcmBuffer)
            } catch {
              writeError = error
            }
          }
        }

        if done.wait(timeout: .now() + 600) == .timedOut {
          settle {
            self.activeFileSynthesizer = nil
            promise.reject("ERR_TTS_FILE_TIMEOUT", "synthesizeToFile timed out after 600s")
          }
        }
      }
    }

    // ----- getVoices -----
    AsyncFunction("getVoices") { () -> [[String: Any]] in
      AVSpeechSynthesisVoice.speechVoices().map { voice in
        var quality = "default"
        if #available(iOS 16.0, *), voice.quality == .premium {
          quality = "premium"
        } else if #available(iOS 9.0, *), voice.quality == .enhanced {
          quality = "enhanced"
        }
        return [
          "identifier": voice.identifier,
          "name": voice.name,
          "language": voice.language,
          "quality": quality
        ]
      }
    }

    // ----- stop -----
    Function("stop") {
      self.synthesizer.stopSpeaking(at: .immediate)
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
      // .playback + .spokenAudio keeps synthesis off the 16 kHz telephony path.
      try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
      // Request native media sample rate before activation (hardware may still negotiate).
      try audioSession.setPreferredSampleRate(44_100)
      try audioSession.setActive(true)
    } catch {
      print("[LocalTtsModule] AudioSession configuration warning: \(error.localizedDescription)")
    }
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
    // Rate: map user 1.0 (normal) to AVSpeechUtteranceDefaultSpeechRate.
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
    utterance.pitchMultiplier = Float(pitch)
    // Micro-pause between utterance chunks for more natural pacing
    utterance.postUtteranceDelay = 0.12

    // Priority 1: explicit voice identifier
    if !voice.isEmpty {
      if let foundVoice = AVSpeechSynthesisVoice(identifier: voice) {
        utterance.voice = foundVoice
        return utterance
      }
      print("[LocalTtsModule] Specified voice identifier '\(voice)' not found, attempting language fallback.")
    }

    // Priority 2: best installed voice for language (premium > enhanced > default)
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
