import { NativeModule, requireNativeModule, EventEmitter } from "expo";
import type {
  ConcatWavOptions,
  LocalTtsEvents,
  SpeakOptions,
  SpeechErrorEvent,
  SpeechProgressEvent,
  Subscription,
  SynthesizeFileResult,
  SynthesizeOptions,
  SynthesizeUtterancesOptions,
  VoiceInfo,
} from "./types";

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/**
 * Thrown when the native LocalTts module is not available on the current
 * platform or build (for example Expo Go, or an app that was not rebuilt
 * after installing this package).
 */
export class LocalTtsUnavailableError extends Error {
  constructor() {
    super(
      "[react-native-local-tts] Native module is not available. " +
        "Ensure you have a dev client or standalone build with the native module installed."
    );
    this.name = "LocalTtsUnavailableError";
  }
}

// ---------------------------------------------------------------------------
// Native Module Binding
// ---------------------------------------------------------------------------

type LocalTtsModuleType = InstanceType<typeof NativeModule> & {
  speak(options: {
    text: string;
    rate: number;
    pitch: number;
    language: string;
    voice: string;
    qualityMode: boolean;
  }): Promise<void>;

  synthesizeToFile(options: {
    text: string;
    filePath: string;
    rate: number;
    pitch: number;
    language: string;
    voice: string;
    qualityMode: boolean;
  }): Promise<SynthesizeFileResult | void>;

  synthesizeUtterancesToFile(options: {
    utterances: Array<{
      text: string;
      rate: number;
      pitch: number;
      trailingSilenceMs: number;
    }>;
    filePath: string;
    language: string;
    voice: string;
    qualityMode: boolean;
  }): Promise<SynthesizeFileResult>;

  concatWavFiles(options: {
    inputPaths: string[];
    outputPath: string;
  }): Promise<SynthesizeFileResult>;

  getVoices(): Promise<VoiceInfo[]>;

  stop(): void;

  isSpeaking(): boolean;
};

let NativeLocalTts: LocalTtsModuleType | null = null;

try {
  NativeLocalTts = requireNativeModule<LocalTtsModuleType>("LocalTtsModule");
} catch {
  NativeLocalTts = null;
}

const emitter = NativeLocalTts
  ? new EventEmitter<LocalTtsEvents>(NativeLocalTts)
  : null;

/** Whether the native LocalTts module is available on the current platform. */
export const isAvailable = NativeLocalTts != null;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function normalizeSpeak(options: SpeakOptions) {
  return {
    text: options.text,
    rate: options.rate ?? 1.0,
    pitch: options.pitch ?? 1.0,
    language: options.language ?? "",
    voice: options.voice ?? "",
    // Preview should sound like System Settings by default.
    qualityMode: options.qualityMode ?? true,
  };
}

function normalizeSynthesize(options: SynthesizeOptions) {
  const filePath = options.filePath.replace(/^file:\/\//, "");
  return {
    text: options.text,
    filePath,
    rate: options.rate ?? 1.0,
    pitch: options.pitch ?? 1.0,
    language: options.language ?? "",
    voice: options.voice ?? "",
    // Book conversion defaults to the faster routing path.
    qualityMode: options.qualityMode ?? false,
  };
}

function normalizeSynthesizeUtterances(options: SynthesizeUtterancesOptions) {
  const filePath = options.filePath.replace(/^file:\/\//, "");
  return {
    utterances: options.utterances.map((utterance) => ({
      text: utterance.text,
      rate: utterance.rate ?? 1.0,
      pitch: utterance.pitch ?? 1.0,
      trailingSilenceMs: utterance.trailingSilenceMs ?? 0,
    })),
    filePath,
    language: options.language ?? "",
    voice: options.voice ?? "",
    qualityMode: options.qualityMode ?? false,
  };
}

function assertWavFilePath(filePath: string): void {
  if (!filePath.toLowerCase().endsWith(".wav")) {
    throw new Error(
      "[react-native-local-tts] synthesizeToFile requires a .wav filePath"
    );
  }
}

function coerceSynthesizeResult(
  result: SynthesizeFileResult | void,
  fallbackSampleRate = 22050
): SynthesizeFileResult {
  if (
    result &&
    typeof result.durationSeconds === "number" &&
    typeof result.sampleRate === "number"
  ) {
    return {
      durationSeconds: result.durationSeconds,
      sampleRate: result.sampleRate,
      frameCount:
        result.frameCount ?? Math.round(result.durationSeconds * result.sampleRate),
    };
  }
  return {
    durationSeconds: 0,
    sampleRate: fallbackSampleRate,
    frameCount: 0,
  };
}

// ---------------------------------------------------------------------------
// Public API — Speech
// ---------------------------------------------------------------------------

/**
 * Speaks the given text aloud using the device's native TTS engine.
 *
 * The returned promise resolves when speech has **finished** (not when it
 * starts). Use {@link onSpeechProgress} to receive word-level progress
 * callbacks while speech is in progress.
 *
 * @throws {LocalTtsUnavailableError} If the native module is not installed.
 *
 * @example
 * await speak({ text: "Hello, world!", language: "en-US", rate: 1.0 });
 */
export async function speak(options: SpeakOptions): Promise<void> {
  if (!NativeLocalTts) throw new LocalTtsUnavailableError();
  return NativeLocalTts.speak(normalizeSpeak(options));
}

/**
 * Synthesizes text to an audio file on disk using the device's native TTS
 * engine. The promise resolves once the entire file has been written.
 *
 * - **iOS**: Uses `AVSpeechSynthesizer.write(_:toBufferCallback:)`, converts
 *   buffers to Int16 mono PCM, and writes a `.wav` via `AVAudioFile`.
 * - **Android**: Uses `TextToSpeech.synthesizeToFile()` which writes a `.wav`.
 *
 * `filePath` must end with `.wav`. The `file://` prefix is optional.
 *
 * @throws {LocalTtsUnavailableError} If the native module is not installed.
 *
 * @example
 * await synthesizeToFile({
 *   text: "Saved for later.",
 *   filePath: `${documentDirectory}speech.wav`,
 *   language: "en-US",
 * });
 */
export async function synthesizeToFile(options: SynthesizeOptions): Promise<void> {
  if (!NativeLocalTts) throw new LocalTtsUnavailableError();
  const normalized = normalizeSynthesize(options);
  assertWavFilePath(normalized.filePath);
  await NativeLocalTts.synthesizeToFile(normalized);
}

/**
 * Streams many utterances into a single `.wav` on disk.
 *
 * Native code keeps only a small PCM scratch buffer in RAM and appends silence
 * between utterances — preferred for long-form / book conversion so JS does not
 * hold full-chapter audio in memory.
 *
 * Returns timing metadata (`durationSeconds`, `sampleRate`, `frameCount`) without
 * requiring a JS-side decode of the file.
 *
 * @throws {LocalTtsUnavailableError} If the native module is not installed.
 * @throws If this native build predates the multi-utterance API (rebuild required).
 *
 * @example
 * const result = await synthesizeUtterancesToFile({
 *   filePath: "/path/chapter.wav",
 *   utterances: [
 *     { text: "First paragraph.", trailingSilenceMs: 400 },
 *     { text: "Second paragraph.", trailingSilenceMs: 600 },
 *   ],
 * });
 */
export async function synthesizeUtterancesToFile(
  options: SynthesizeUtterancesOptions
): Promise<SynthesizeFileResult> {
  if (!NativeLocalTts) throw new LocalTtsUnavailableError();
  const normalized = normalizeSynthesizeUtterances(options);
  assertWavFilePath(normalized.filePath);
  if (typeof NativeLocalTts.synthesizeUtterancesToFile !== "function") {
    throw new Error(
      "[react-native-local-tts] synthesizeUtterancesToFile is not available in this native build. Rebuild the app."
    );
  }
  const result = await NativeLocalTts.synthesizeUtterancesToFile(normalized);
  return coerceSynthesizeResult(result);
}

/**
 * Concatenates Int16 WAV parts into one file by streaming PCM.
 *
 * Used to stitch batched chapter synthesis without holding full-chapter audio
 * in JS RAM. Parses each file’s real `data` chunk (does not assume a classic
 * 44-byte header — important for `AVAudioFile` output).
 *
 * @throws {LocalTtsUnavailableError} If the native module is not installed.
 * @throws If this native build predates `concatWavFiles` (rebuild required).
 *
 * @example
 * const { durationSeconds } = await concatWavFiles({
 *   inputPaths: ["/path/part0.wav", "/path/part1.wav"],
 *   outputPath: "/path/chapter.wav",
 * });
 */
export async function concatWavFiles(
  options: ConcatWavOptions
): Promise<SynthesizeFileResult> {
  if (!NativeLocalTts) throw new LocalTtsUnavailableError();
  const outputPath = options.outputPath.replace(/^file:\/\//, "");
  assertWavFilePath(outputPath);
  if (typeof NativeLocalTts.concatWavFiles !== "function") {
    throw new Error(
      "[react-native-local-tts] concatWavFiles is not available in this native build. Rebuild the app."
    );
  }
  const result = await NativeLocalTts.concatWavFiles({
    inputPaths: options.inputPaths.map((path) => path.replace(/^file:\/\//, "")),
    outputPath,
  });
  return coerceSynthesizeResult(result);
}

/**
 * Returns a list of all available TTS voices on the device.
 *
 * Identifiers are platform-specific — prefer picking a voice from this list
 * and passing `identifier` to `speak` / synthesize options rather than
 * hard-coding strings across iOS and Android.
 *
 * @throws {LocalTtsUnavailableError} If the native module is not installed.
 */
export async function getVoices(): Promise<VoiceInfo[]> {
  if (!NativeLocalTts) throw new LocalTtsUnavailableError();
  return NativeLocalTts.getVoices();
}

/**
 * Immediately stops any in-progress speech. No-op if nothing is playing.
 *
 * Affects live `speak` playback. In-flight file synthesis is managed by the
 * native job queue separately.
 *
 * @throws {LocalTtsUnavailableError} If the native module is not installed.
 */
export function stop(): void {
  if (!NativeLocalTts) throw new LocalTtsUnavailableError();
  NativeLocalTts.stop();
}

/**
 * Returns `true` if the TTS engine is currently speaking (live playback).
 *
 * @throws {LocalTtsUnavailableError} If the native module is not installed.
 */
export function isSpeaking(): boolean {
  if (!NativeLocalTts) throw new LocalTtsUnavailableError();
  return NativeLocalTts.isSpeaking();
}

/**
 * Subscribes to word-level progress events during speech.
 *
 * Fires for each word as it is spoken. On Android, requires API 26+
 * (`onRangeStart`); older devices still receive start / done / error.
 *
 * @returns A subscription with `remove()` to unsubscribe.
 */
export function onSpeechProgress(
  listener: (event: SpeechProgressEvent) => void
): Subscription {
  if (!emitter) throw new LocalTtsUnavailableError();
  return emitter.addListener("onSpeechProgress", listener);
}

/**
 * Subscribes to the speech-start event.
 *
 * @returns A subscription with `remove()` to unsubscribe.
 */
export function onSpeechStart(listener: () => void): Subscription {
  if (!emitter) throw new LocalTtsUnavailableError();
  return emitter.addListener("onSpeechStart", () => {
    listener();
  });
}

/**
 * Subscribes to the speech-done event (finished or cancelled).
 *
 * @returns A subscription with `remove()` to unsubscribe.
 */
export function onSpeechDone(listener: () => void): Subscription {
  if (!emitter) throw new LocalTtsUnavailableError();
  return emitter.addListener("onSpeechDone", () => {
    listener();
  });
}

/**
 * Subscribes to speech engine error events.
 *
 * @returns A subscription with `remove()` to unsubscribe.
 */
export function onSpeechError(
  listener: (error: SpeechErrorEvent) => void
): Subscription {
  if (!emitter) throw new LocalTtsUnavailableError();
  return emitter.addListener("onSpeechError", listener);
}
