import { NativeModule, requireNativeModule, EventEmitter } from "expo";
import type {
  LocalTtsEvents,
  SpeakOptions,
  SpeechErrorEvent,
  SpeechProgressEvent,
  Subscription,
  SynthesizeOptions,
  VoiceInfo,
} from "./types";

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/**
 * Thrown when the native LocalTts module is not available on the current
 * platform or build.
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
  }): Promise<void>;

  synthesizeToFile(options: {
    text: string;
    filePath: string;
    rate: number;
    pitch: number;
    language: string;
    voice: string;
  }): Promise<void>;

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
  };
}

function normalizeSynthesize(options: SynthesizeOptions) {
  return {
    text: options.text,
    filePath: options.filePath,
    rate: options.rate ?? 1.0,
    pitch: options.pitch ?? 1.0,
    language: options.language ?? "",
    voice: options.voice ?? "",
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
 * - **iOS**: Uses `AVSpeechSynthesizer.write(_:toBufferCallback:)` to capture
 *   PCM buffers, converts them to Int16 mono, then writes a `.wav` via `AVAudioFile`.
 * - **Android**: Uses `TextToSpeech.synthesizeToFile()` which writes a `.wav`.
 *
 * @throws {LocalTtsUnavailableError} If the native module is not installed.
 */
export async function synthesizeToFile(options: SynthesizeOptions): Promise<void> {
  if (!NativeLocalTts) throw new LocalTtsUnavailableError();
  return NativeLocalTts.synthesizeToFile(normalizeSynthesize(options));
}

/**
 * Returns a list of all available TTS voices on the device.
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
 * @throws {LocalTtsUnavailableError} If the native module is not installed.
 */
export function stop(): void {
  if (!NativeLocalTts) throw new LocalTtsUnavailableError();
  NativeLocalTts.stop();
}

/**
 * Returns `true` if the TTS engine is currently speaking.
 *
 * @throws {LocalTtsUnavailableError} If the native module is not installed.
 */
export function isSpeaking(): boolean {
  if (!NativeLocalTts) throw new LocalTtsUnavailableError();
  return NativeLocalTts.isSpeaking();
}

/**
 * Subscribes to word-level progress events during speech.
 */
export function onSpeechProgress(
  listener: (event: SpeechProgressEvent) => void
): Subscription {
  if (!emitter) throw new LocalTtsUnavailableError();
  return emitter.addListener("onSpeechProgress", listener);
}

/**
 * Subscribes to the speech-start event.
 */
export function onSpeechStart(listener: () => void): Subscription {
  if (!emitter) throw new LocalTtsUnavailableError();
  return emitter.addListener("onSpeechStart", () => {
    listener();
  });
}

/**
 * Subscribes to the speech-done event.
 */
export function onSpeechDone(listener: () => void): Subscription {
  if (!emitter) throw new LocalTtsUnavailableError();
  return emitter.addListener("onSpeechDone", () => {
    listener();
  });
}

/**
 * Subscribes to speech error events.
 */
export function onSpeechError(
  listener: (error: SpeechErrorEvent) => void
): Subscription {
  if (!emitter) throw new LocalTtsUnavailableError();
  return emitter.addListener("onSpeechError", listener);
}
