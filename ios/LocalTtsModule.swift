import ExpoModulesCore
import AVFoundation

// ---------------------------------------------------------------------------
// Expo Module Definition
// ---------------------------------------------------------------------------

public class LocalTtsModule: Module, @unchecked Sendable {
  private let synthQueue = DispatchQueue(label: "expo.modules.localtts.synth")
  private var synthesizer = AVSpeechSynthesizer()
  private var speakDelegate: SpeechDelegate?

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
          onError: { message in
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

        let utterance = AVSpeechUtterance(string: options.text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(options.rate)
        utterance.pitchMultiplier = Float(options.pitch)
        
        if !options.language.isEmpty {
          utterance.voice = AVSpeechSynthesisVoice(language: options.language)
        }
        if !options.voice.isEmpty {
          if let found = AVSpeechSynthesisVoice(identifier: options.voice) {
            utterance.voice = found
          }
        }

        let fileURL = URL(fileURLWithPath: options.filePath)

        // Ensure parent directory exists
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var audioFile: AVAudioFile?
        var writeError: Error?
        var fileSynthesizer: AVSpeechSynthesizer? = AVSpeechSynthesizer()

        fileSynthesizer?.write(utterance) { buffer in
          guard let pcmBuffer = buffer as? AVAudioPCMBuffer,
                pcmBuffer.frameLength > 0 else {
            // Empty buffer signals completion
            if let err = writeError {
              promise.reject("ERR_TTS_FILE_WRITE", err.localizedDescription)
            } else {
              promise.resolve(nil)
            }
            fileSynthesizer = nil // Break the retain cycle
            return
          }

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
    }

    // ----- getVoices -----
    AsyncFunction("getVoices") { () -> [[String: Any]] in
      AVSpeechSynthesisVoice.speechVoices().map { voice in
        var quality = "default"
        if #available(iOS 9.0, *) {
          switch voice.quality {
          case .enhanced: quality = "enhanced"
          case .premium:  quality = "premium"
          default:        quality = "default"
          }
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

  private func buildUtterance(_ options: SpeakOptions) -> AVSpeechUtterance {
    let utterance = AVSpeechUtterance(string: options.text)
    // Rate: AVSpeechUtterance expects 0..1 range where 0.5 is default.
    // We map the user's 1.0 (normal) to AVSpeechUtteranceDefaultSpeechRate.
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(options.rate)
    utterance.pitchMultiplier = Float(options.pitch)

    if !options.language.isEmpty {
      utterance.voice = AVSpeechSynthesisVoice(language: options.language)
    }
    if !options.voice.isEmpty {
      if let found = AVSpeechSynthesisVoice(identifier: options.voice) {
        utterance.voice = found
      }
    }
    return utterance
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
