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
// 4. Audio routing is controlled by `qualityMode`:
//    - true  → session `.default`  + usesApplicationAudioSession = false (natural timbre)
//    - false → session `.spokenAudio` + usesApplicationAudioSession = true (faster)
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
  private var pendingFileJobs: [FileJob] = []
  private var lastFileQualityMode: Bool?

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
        self.applyAudioRouting(
          synthesizer: self.speakSynthesizer,
          qualityMode: options.qualityMode,
          forFileSynthesis: false
        )

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
        self.pendingFileJobs.append(.single(options, promise))
        self.startNextFileJobIfNeeded()
      }
    }

    AsyncFunction("synthesizeUtterancesToFile") { (options: SynthesizeUtterancesOptions, promise: Promise) in
      guard #available(iOS 13.0, *) else {
        promise.reject("ERR_TTS_UNSUPPORTED", "synthesizeUtterancesToFile requires iOS 13+")
        return
      }

      let trimmed = options.utterances.filter {
        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      guard !trimmed.isEmpty else {
        promise.reject("ERR_TTS_FILE", "synthesizeUtterancesToFile requires non-empty utterances")
        return
      }

      let fileURL = URL(fileURLWithPath: options.filePath)
      guard fileURL.pathExtension.lowercased() == "wav" else {
        promise.reject(
          "ERR_TTS_FILE_PATH",
          "synthesizeUtterancesToFile requires a .wav filePath"
        )
        return
      }

      self.fileJobQueue.async {
        self.pendingFileJobs.append(.multi(options, promise))
        self.startNextFileJobIfNeeded()
      }
    }

    AsyncFunction("concatWavFiles") { (options: ConcatWavOptions, promise: Promise) in
      let inputs = options.inputPaths
        .map { $0.replacingOccurrences(of: "file://", with: "") }
        .filter { !$0.isEmpty }
      let outputPath = options.outputPath.replacingOccurrences(of: "file://", with: "")

      guard !inputs.isEmpty else {
        promise.reject("ERR_TTS_CONCAT", "concatWavFiles requires at least one input path")
        return
      }
      guard outputPath.lowercased().hasSuffix(".wav") else {
        promise.reject("ERR_TTS_CONCAT", "concatWavFiles requires a .wav outputPath")
        return
      }

      DispatchQueue.global(qos: .utility).async {
        do {
          let outputURL = URL(fileURLWithPath: outputPath)
          try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try? FileManager.default.removeItem(at: outputURL)

          let inputURLs = inputs.map { URL(fileURLWithPath: $0) }
          let result = try Self.concatWavFilesStreaming(inputs: inputURLs, output: outputURL)
          promise.resolve([
            "durationSeconds": result.durationSeconds,
            "sampleRate": result.sampleRate,
            "frameCount": result.frameCount
          ])
        } catch {
          promise.reject("ERR_TTS_CONCAT", error.localizedDescription)
        }
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
    // Routing is applied per job via applyAudioRouting(qualityMode:).
    fileSynthesizer = synth
    return synth
  }

  private func startNextFileJobIfNeeded() {
    guard !fileJobRunning, !pendingFileJobs.isEmpty else { return }
    fileJobRunning = true
    let job = pendingFileJobs.removeFirst()

    // Prepare file URL / utterances off main (may touch voice XPC).
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }

      switch job {
      case let .single(options, promise):
        let fileURL = URL(fileURLWithPath: options.filePath)
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: fileURL)

        let utterance = self.buildUtterance(options)
        // Fresh synthesizer per job avoids wedged write() state between chapters.
        self.resetFileSynthesizer()
        let synth = self.ensureFileSynthesizer()

        print(
          "[LocalTtsModule] synthesizeToFile enqueue chars=\(options.text.count) voice=\(options.voice) file=\(fileURL.lastPathComponent)"
        )

        DispatchQueue.main.async {
          self.beginWriteOnMain(
            synthesizer: synth,
            utterances: [
              PlannedUtterance(utterance: utterance, trailingSilenceMs: 0)
            ],
            fileURL: fileURL,
            qualityMode: options.qualityMode,
            promise: promise
          )
        }

      case let .multi(options, promise):
        let fileURL = URL(fileURLWithPath: options.filePath)
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: fileURL)

        let specs = options.utterances.filter {
          !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let planned: [PlannedUtterance] = specs.map { spec in
          PlannedUtterance(
            utterance: self.createUtterance(
              text: spec.text,
              rate: spec.rate,
              pitch: spec.pitch,
              language: options.language,
              voice: options.voice
            ),
            trailingSilenceMs: spec.trailingSilenceMs
          )
        }
        self.resetFileSynthesizer()
        let synth = self.ensureFileSynthesizer()
        let totalChars = specs.reduce(0) { $0 + $1.text.count }

        print(
          "[LocalTtsModule] synthesizeUtterancesToFile enqueue count=\(planned.count) chars=\(totalChars) voice=\(options.voice) file=\(fileURL.lastPathComponent)"
        )

        DispatchQueue.main.async {
          self.beginWriteOnMain(
            synthesizer: synth,
            utterances: planned,
            fileURL: fileURL,
            qualityMode: options.qualityMode,
            promise: promise
          )
        }
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

  /// Streams one or more utterances into a single Int16 mono WAV.
  /// Keeps only one PCM scratch buffer in memory (plus current AVSpeech buffer).
  /// Must be called on the main queue.
  private func beginWriteOnMain(
    synthesizer: AVSpeechSynthesizer,
    utterances: [PlannedUtterance],
    fileURL: URL,
    qualityMode: Bool,
    promise: Promise
  ) {
    assert(Thread.isMainThread)
    guard !utterances.isEmpty else {
      promise.reject("ERR_TTS_FILE", "No utterances to synthesize")
      finishFileJob()
      return
    }

    applyAudioRouting(synthesizer: synthesizer, qualityMode: qualityMode, forFileSynthesis: true)

    let wasSpeaking = synthesizer.isSpeaking
    if wasSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }

    var writeError: Error?
    var didSettle = false
    let settleLock = NSLock()
    var utteranceIndex = 0
    /// Bumped when an utterance's write() completes so late callbacks are ignored.
    var writeGeneration = 0
    let sink = Int16MonoWavSink(fileURL: fileURL)
    let progressLock = NSLock()
    var lastProgressAt = Date()
    var buffersWritten = 0

    let totalChars = utterances.reduce(0) { $0 + $1.utterance.speechString.count }
    // Absolute ceiling scales with content; idle watchdog catches true hangs.
    // Cap at 12h so multi-hour single chapters are not killed arbitrarily.
    let absoluteTimeoutSeconds = min(
      12 * 60 * 60.0,
      max(600.0, Double(totalChars) / 6.0 + Double(utterances.count) * 60.0)
    )
    // Fail only if we stop receiving buffers for this long (true hang).
    let idleTimeoutSeconds: TimeInterval = 120

    func markProgress() {
      progressLock.lock()
      lastProgressAt = Date()
      buffersWritten += 1
      progressLock.unlock()
    }

    func settle(_ body: () -> Void) {
      settleLock.lock()
      defer { settleLock.unlock() }
      guard !didSettle else { return }
      didSettle = true
      body()
      self.finishFileJob()
    }

    let absoluteTimeoutWork = DispatchWorkItem {
      progressLock.lock()
      let idle = Date().timeIntervalSince(lastProgressAt)
      let buffers = buffersWritten
      progressLock.unlock()
      print(
        "[LocalTtsModule] synthesize*ToFile ABSOLUTE TIMEOUT \(fileURL.lastPathComponent) idle=\(Int(idle))s buffers=\(buffers)"
      )
      settle {
        synthesizer.stopSpeaking(at: .immediate)
        sink.close()
        promise.reject(
          "ERR_TTS_FILE_TIMEOUT",
          "File synthesis exceeded \(Int(absoluteTimeoutSeconds))s (buffers=\(buffers), idle=\(Int(idle))s)"
        )
      }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + absoluteTimeoutSeconds,
      execute: absoluteTimeoutWork
    )

    let idleWatchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    idleWatchdog.schedule(deadline: .now() + 5, repeating: 5)
    idleWatchdog.setEventHandler {
      progressLock.lock()
      let idle = Date().timeIntervalSince(lastProgressAt)
      let buffers = buffersWritten
      progressLock.unlock()
      guard idle >= idleTimeoutSeconds else { return }
      print(
        "[LocalTtsModule] synthesize*ToFile IDLE TIMEOUT \(fileURL.lastPathComponent) idle=\(Int(idle))s buffers=\(buffers) utterance=\(utteranceIndex)/\(utterances.count)"
      )
      absoluteTimeoutWork.cancel()
      settle {
        synthesizer.stopSpeaking(at: .immediate)
        sink.close()
        // Recreate synthesizer — write() can wedge after a hung premium-voice job.
        self.resetFileSynthesizer()
        promise.reject(
          "ERR_TTS_FILE_TIMEOUT",
          "File synthesis stalled for \(Int(idle))s with no audio buffers (utterance \(utteranceIndex)/\(utterances.count), buffers=\(buffers))"
        )
      }
    }
    idleWatchdog.resume()

    func cancelWatchdogs() {
      absoluteTimeoutWork.cancel()
      idleWatchdog.cancel()
    }

    func resolveSuccess() {
      cancelWatchdogs()
      sink.close()
      settle {
        if !sink.didWriteAudio {
          promise.reject("ERR_TTS_FILE_EMPTY", "File synthesis produced no audio buffers")
          return
        }
        let sampleRate = sink.sampleRate > 0 ? sink.sampleRate : 22_050
        let duration = Double(sink.totalFrames) / sampleRate
        print(
          "[LocalTtsModule] synthesize*ToFile OK \(fileURL.lastPathComponent) frames=\(sink.totalFrames) duration=\(String(format: "%.2f", duration))s buffers=\(buffersWritten)"
        )
        promise.resolve([
          "durationSeconds": duration,
          "sampleRate": sampleRate,
          "frameCount": sink.totalFrames
        ])
      }
    }

    func writeCurrentUtterance() {
      guard writeError == nil, !didSettle else { return }
      guard utteranceIndex < utterances.count else {
        resolveSuccess()
        return
      }

      let planned = utterances[utteranceIndex]
      utteranceIndex += 1
      markProgress()
      let framesBeforeUtterance = sink.totalFrames
      writeGeneration += 1
      let generation = writeGeneration

      print(
        "[LocalTtsModule] write utterance \(utteranceIndex)/\(utterances.count) chars=\(planned.utterance.speechString.count) edges=\"\(Self.textEdgePreview(planned.utterance.speechString))\""
      )

      synthesizer.write(planned.utterance) { buffer in
        guard generation == writeGeneration else { return }
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
        if writeError != nil || didSettle { return }

        // Only frameLength == 0 means end-of-utterance. Treating short/silent
        // Float32 pads as terminal starts the next write() while buffers are still
        // arriving and drops the rest of the chapter at the same utterance boundary.
        let isTerminalBuffer = pcmBuffer.frameLength == 0

        if isTerminalBuffer {
          markProgress()
          // Invalidate further callbacks from this write before starting the next.
          writeGeneration += 1
          let framesForUtterance = sink.totalFrames - framesBeforeUtterance
          print(
            "[LocalTtsModule] finished utterance \(utteranceIndex)/\(utterances.count) wroteFrames=\(framesForUtterance) totalFrames=\(sink.totalFrames)"
          )
          do {
            if planned.trailingSilenceMs > 0 {
              let rate = sink.sampleRate > 0 ? sink.sampleRate : 22_050
              try sink.writeSilence(milliseconds: planned.trailingSilenceMs, sampleRate: rate)
            }
          } catch {
            writeError = error
            cancelWatchdogs()
            synthesizer.stopSpeaking(at: .immediate)
            sink.close()
            settle {
              promise.reject("ERR_TTS_FILE_WRITE", error.localizedDescription)
            }
            return
          }

          // Continue on next main-loop turn so we don't nest write() calls.
          DispatchQueue.main.async {
            writeCurrentUtterance()
          }
          return
        }

        markProgress()
        do {
          try sink.write(pcmBuffer)
        } catch {
          writeError = error
          cancelWatchdogs()
          synthesizer.stopSpeaking(at: .immediate)
          sink.close()
          settle {
            promise.reject("ERR_TTS_FILE_WRITE", error.localizedDescription)
          }
        }
      }
    }

    print(
      "[LocalTtsModule] synthesize*ToFile START on main \(fileURL.lastPathComponent) utterances=\(utterances.count) chars=\(totalChars) absoluteTimeout=\(Int(absoluteTimeoutSeconds))s"
    )

    // stopSpeaking can leave write() wedged if we start immediately.
    if wasSpeaking {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        writeCurrentUtterance()
      }
    } else {
      writeCurrentUtterance()
    }
  }

  private func resetFileSynthesizer() {
    fileSynthesizerLock.lock()
    defer { fileSynthesizerLock.unlock() }
    fileSynthesizer?.stopSpeaking(at: .immediate)
    fileSynthesizer = nil
    lastFileQualityMode = nil
  }

  // MARK: - Audio sessions

  /// Applies iOS routing for quality vs speed.
  /// - qualityMode true: session `.default` (natural neural timbre)
  /// - qualityMode false: session `.spokenAudio` (faster / more compatible)
  /// Live `speak` may set `usesApplicationAudioSession = false` for timbre.
  /// Offline `write` always keeps it `true` — `false` has crashed file synthesis.
  private func applyAudioRouting(
    synthesizer: AVSpeechSynthesizer,
    qualityMode: Bool,
    forFileSynthesis: Bool
  ) {
    synthesizer.usesApplicationAudioSession = forFileSynthesis ? true : !qualityMode

    // Skip redundant session churn during long book conversions.
    if forFileSynthesis, let fileSynthesizer, synthesizer === fileSynthesizer {
      if lastFileQualityMode == qualityMode {
        return
      }
      lastFileQualityMode = qualityMode
    }

    do {
      let audioSession = AVAudioSession.sharedInstance()
      let mode: AVAudioSession.Mode = qualityMode ? .default : .spokenAudio
      try audioSession.setCategory(.playback, mode: mode, options: [.duckOthers])
      try audioSession.setPreferredSampleRate(44_100)
      try audioSession.setActive(true)
    } catch {
      print("[LocalTtsModule] AudioSession warning: \(error.localizedDescription)")
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

/// Writes a classic 44-byte PCM WAV (Int16 mono). Avoids `AVAudioFile`, which
/// often emits extensible/padded headers that break naive concat and some decoders.
private final class Int16MonoWavSink {
  enum SinkError: LocalizedError {
    case invalidFormat
    case convertFailed
    case ioFailed(String)

    var errorDescription: String? {
      switch self {
      case .invalidFormat:
        return "Failed to create Int16 mono WAV format for TTS output"
      case .convertFailed:
        return "Failed to convert TTS PCM buffer to Int16 mono WAV"
      case .ioFailed(let message):
        return message
      }
    }
  }

  private let fileURL: URL
  private var handle: FileHandle?
  private var outFormat: AVAudioFormat?
  private var scratch: AVAudioPCMBuffer?
  private var headerWritten = false
  private(set) var didWriteAudio = false
  private(set) var totalFrames: Int = 0
  private(set) var sampleRate: Double = 0

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  /// Finalize RIFF/data sizes and close the file.
  func close() {
    defer {
      handle = nil
      scratch = nil
      outFormat = nil
    }
    guard let handle, headerWritten else {
      try? handle?.close()
      return
    }
    do {
      let dataSize = UInt32(truncatingIfNeeded: totalFrames * MemoryLayout<Int16>.size)
      let riffSize = UInt32(36) + dataSize
      try handle.seek(toOffset: 4)
      try Self.writeUInt32LE(handle, riffSize)
      try handle.seek(toOffset: 40)
      try Self.writeUInt32LE(handle, dataSize)
      try handle.synchronize()
      try handle.close()
    } catch {
      print("[LocalTtsModule] WAV close/finalize failed: \(error.localizedDescription)")
      try? handle.close()
    }
  }

  func write(_ buffer: AVAudioPCMBuffer) throws {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return }

    try ensureOpen(sampleRate: buffer.format.sampleRate)
    guard let outFormat, let handle else {
      throw SinkError.invalidFormat
    }

    let out = try ensureScratch(capacity: frames, format: outFormat)
    out.frameLength = AVAudioFrameCount(frames)
    try fillInt16Mono(from: buffer, into: out)
    guard let dstRaw = out.mutableAudioBufferList.pointee.mBuffers.mData else {
      throw SinkError.convertFailed
    }
    let byteCount = frames * MemoryLayout<Int16>.size
    try handle.write(contentsOf: Data(bytes: dstRaw, count: byteCount))
    totalFrames += frames
    didWriteAudio = true
  }

  /// Writes silence in small chunks so long pauses do not allocate a huge buffer.
  func writeSilence(milliseconds: Double, sampleRate rate: Double) throws {
    guard milliseconds > 0 else { return }
    let effectiveRate = rate > 0 ? rate : (self.sampleRate > 0 ? self.sampleRate : 22_050)
    let totalSilenceFrames = Int((effectiveRate * milliseconds / 1000.0).rounded())
    guard totalSilenceFrames > 0 else { return }

    try ensureOpen(sampleRate: effectiveRate)
    guard let handle else {
      throw SinkError.invalidFormat
    }

    let chunkFrames = 4096
    var remaining = totalSilenceFrames
    let zeroChunk = [UInt8](repeating: 0, count: chunkFrames * MemoryLayout<Int16>.size)
    while remaining > 0 {
      let frames = min(chunkFrames, remaining)
      let byteCount = frames * MemoryLayout<Int16>.size
      try handle.write(contentsOf: Data(zeroChunk.prefix(byteCount)))
      totalFrames += frames
      remaining -= frames
    }
    didWriteAudio = true
  }

  private func ensureOpen(sampleRate rate: Double) throws {
    if headerWritten { return }

    try? FileManager.default.removeItem(at: fileURL)
    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: fileURL)
    self.handle = handle

    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: rate,
        channels: 1,
        interleaved: true
      )
    else {
      throw SinkError.invalidFormat
    }
    outFormat = format
    sampleRate = rate

    // Classic PCM WAV header; sizes patched in close().
    var header = Data()
    header.append(contentsOf: Array("RIFF".utf8))
    Self.appendUInt32LE(&header, 36) // placeholder riff size
    header.append(contentsOf: Array("WAVE".utf8))
    header.append(contentsOf: Array("fmt ".utf8))
    Self.appendUInt32LE(&header, 16) // PCM fmt chunk size
    Self.appendUInt16LE(&header, 1) // audio format = PCM
    Self.appendUInt16LE(&header, 1) // channels
    Self.appendUInt32LE(&header, UInt32(rate.rounded()))
    let byteRate = UInt32(rate.rounded()) * 2 // mono Int16
    Self.appendUInt32LE(&header, byteRate)
    Self.appendUInt16LE(&header, 2) // block align
    Self.appendUInt16LE(&header, 16) // bits per sample
    header.append(contentsOf: Array("data".utf8))
    Self.appendUInt32LE(&header, 0) // placeholder data size
    try handle.write(contentsOf: header)
    headerWritten = true
  }

  private static func appendUInt16LE(_ data: inout Data, _ value: UInt16) {
    var le = value.littleEndian
    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
  }

  private static func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
    var le = value.littleEndian
    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
  }

  private static func writeUInt32LE(_ handle: FileHandle, _ value: UInt32) throws {
    var le = value.littleEndian
    try withUnsafeBytes(of: &le) { try handle.write(contentsOf: Data($0)) }
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
  @Field var qualityMode: Bool = true
}

private struct SynthesizeOptions: Record {
  @Field var text: String = ""
  @Field var filePath: String = ""
  @Field var rate: Double = 1.0
  @Field var pitch: Double = 1.0
  @Field var language: String = ""
  @Field var voice: String = ""
  @Field var qualityMode: Bool = false
}

private struct UtteranceSpec: Record {
  @Field var text: String = ""
  @Field var rate: Double = 1.0
  @Field var pitch: Double = 1.0
  @Field var trailingSilenceMs: Double = 0
}

private struct SynthesizeUtterancesOptions: Record {
  @Field var utterances: [UtteranceSpec] = []
  @Field var filePath: String = ""
  @Field var language: String = ""
  @Field var voice: String = ""
  @Field var qualityMode: Bool = false
}

private struct ConcatWavOptions: Record {
  @Field var inputPaths: [String] = []
  @Field var outputPath: String = ""
}

private struct PlannedUtterance {
  let utterance: AVSpeechUtterance
  let trailingSilenceMs: Double
}

private enum FileJob {
  case single(SynthesizeOptions, Promise)
  case multi(SynthesizeUtterancesOptions, Promise)
}

private struct WavConcatResult {
  let durationSeconds: Double
  let sampleRate: Double
  let frameCount: Int
}

/// Layout of a PCM WAV — AVAudioFile often uses headers larger than the classic 44 bytes
/// (extensible fmt, FLLR padding, etc.), so callers must not assume fixed offsets.
private struct WavPCMLayout {
  let dataSizeFieldOffset: Int
  let pcmOffset: Int
  let sampleRate: Double
  let channels: Int
  let bitsPerSample: Int
  var bytesPerFrame: Int { max(1, channels * bitsPerSample / 8) }
}

extension LocalTtsModule {
  fileprivate static func textEdgePreview(_ text: String, edge: Int = 30) -> String {
    let collapsed = text
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if collapsed.count <= edge * 2 {
      return collapsed
    }
    let start = collapsed.prefix(edge)
    let end = collapsed.suffix(edge)
    return "\(start) … \(end)"
  }

  fileprivate static func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  fileprivate static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset]) |
      (UInt32(data[offset + 1]) << 8) |
      (UInt32(data[offset + 2]) << 16) |
      (UInt32(data[offset + 3]) << 24)
  }

  fileprivate static func ascii4(_ data: Data, _ offset: Int) -> String {
    guard offset + 4 <= data.count else {return ""}
    return String(data: data.subdata(in: offset..<(offset + 4)), encoding: .ascii) ?? ""
  }

  fileprivate static func parseWavPCMLayout(_ data: Data) throws -> WavPCMLayout {
    guard data.count >= 12, ascii4(data, 0) == "RIFF", ascii4(data, 8) == "WAVE" else {
      throw NSError(
        domain: "LocalTts",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Invalid WAV header (missing RIFF/WAVE)"]
      )
    }

    var offset = 12
    var sampleRate = 22_050.0
    var channels = 1
    var bitsPerSample = 16

    while offset + 8 <= data.count {
      let chunkId = ascii4(data, offset)
      let chunkSize = Int(readUInt32LE(data, offset + 4))
      let payload = offset + 8
      guard chunkSize >= 0, payload <= data.count else {break}

      if chunkId == "fmt ", chunkSize >= 16, payload + 16 <= data.count {
        channels = Int(readUInt16LE(data, payload + 2))
        sampleRate = Double(readUInt32LE(data, payload + 4))
        bitsPerSample = Int(readUInt16LE(data, payload + 14))
      } else if chunkId == "data" {
        return WavPCMLayout(
          dataSizeFieldOffset: offset + 4,
          pcmOffset: payload,
          sampleRate: sampleRate,
          channels: max(1, channels),
          bitsPerSample: bitsPerSample > 0 ? bitsPerSample : 16
        )
      }

      // Chunk payloads are padded to an even byte count.
      offset = payload + chunkSize + (chunkSize & 1)
    }

    throw NSError(
      domain: "LocalTts",
      code: 3,
      userInfo: [NSLocalizedDescriptionKey: "WAV missing data chunk"]
    )
  }

  fileprivate static func probeWavHeader(url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer {try? handle.close()}
    // AVAudioFile may insert padding chunks; 64KB is enough to reach `data`.
    let probe = try handle.read(upToCount: 64 * 1024) ?? Data()
    guard probe.count >= 44 else {
      throw NSError(
        domain: "LocalTts",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "WAV file too small"]
      )
    }
    return probe
  }

  fileprivate static func writeUInt32LE(_ handle: FileHandle, value: UInt32) throws {
    var le = value.littleEndian
    try withUnsafeBytes(of: &le) {try handle.write(contentsOf: Data($0))}
  }

  fileprivate static func copyFileContents(from source: URL, to handle: FileHandle) throws {
    let input = try FileHandle(forReadingFrom: source)
    defer {try? input.close()}
    while true {
      let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
      if chunk.isEmpty {break}
      try handle.write(contentsOf: chunk)
    }
  }

  fileprivate static func copyPCM(from source: URL, pcmOffset: Int, to handle: FileHandle) throws {
    let input = try FileHandle(forReadingFrom: source)
    defer {try? input.close()}
    try input.seek(toOffset: UInt64(pcmOffset))
    while true {
      let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
      if chunk.isEmpty {break}
      try handle.write(contentsOf: chunk)
    }
  }

  /// Remux PCM from each input into a fresh classic 44-byte WAV.
  /// Never reuses AVAudioFile / extensible headers — those were truncating playback.
  fileprivate static func concatWavFilesStreaming(
    inputs: [URL],
    output: URL
  ) throws -> WavConcatResult {
    guard let first = inputs.first else {
      throw NSError(
        domain: "LocalTts",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No WAV inputs to concatenate"]
      )
    }

    let firstLayout = try parseWavPCMLayout(try probeWavHeader(url: first))
    let sampleRate = firstLayout.sampleRate > 0 ? firstLayout.sampleRate : 22_050
    let bytesPerFrame = firstLayout.bytesPerFrame
    print(
      "[LocalTtsModule] concatWav remux pcmOffset=\(firstLayout.pcmOffset) rate=\(Int(sampleRate)) parts=\(inputs.count)"
    )

    try? FileManager.default.removeItem(at: output)
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }

    // Placeholder classic header; sizes patched after PCM is written.
    var header = Data()
    func appendU16(_ v: UInt16) {
      var le = v.littleEndian
      withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
    }
    func appendU32(_ v: UInt32) {
      var le = v.littleEndian
      withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
    }
    header.append(contentsOf: Array("RIFF".utf8))
    appendU32(36)
    header.append(contentsOf: Array("WAVE".utf8))
    header.append(contentsOf: Array("fmt ".utf8))
    appendU32(16)
    appendU16(1) // PCM
    appendU16(UInt16(firstLayout.channels))
    appendU32(UInt32(sampleRate.rounded()))
    appendU32(UInt32(sampleRate.rounded()) * UInt32(bytesPerFrame))
    appendU16(UInt16(bytesPerFrame))
    appendU16(UInt16(firstLayout.bitsPerSample))
    header.append(contentsOf: Array("data".utf8))
    appendU32(0)
    try handle.write(contentsOf: header)

    var totalPcmBytes: Int64 = 0
    for input in inputs {
      let layout = try parseWavPCMLayout(try probeWavHeader(url: input))
      let before = totalPcmBytes
      try copyPCM(from: input, pcmOffset: layout.pcmOffset, to: handle)
      let attrs = try FileManager.default.attributesOfItem(atPath: output.path)
      let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
      totalPcmBytes = max(0, size - 44)
      print(
        "[LocalTtsModule] concatWav appended \(input.lastPathComponent) pcm+=\(totalPcmBytes - before) totalPcm=\(totalPcmBytes)"
      )
    }

    try handle.synchronize()
    let dataSize = UInt32(truncatingIfNeeded: totalPcmBytes)
    let riffSize = UInt32(36) + dataSize
    try handle.seek(toOffset: 4)
    try writeUInt32LE(handle, value: riffSize)
    try handle.seek(toOffset: 40)
    try writeUInt32LE(handle, value: dataSize)
    try handle.synchronize()

    let frameCount = Int(totalPcmBytes) / max(1, bytesPerFrame)
    return WavConcatResult(
      durationSeconds: Double(frameCount) / sampleRate,
      sampleRate: sampleRate,
      frameCount: frameCount
    )
  }
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
