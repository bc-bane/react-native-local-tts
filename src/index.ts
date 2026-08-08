import { NativeModule, requireNativeModule, EventEmitter } from "expo";

type Subscription = { remove: () => void };

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/**
 * Options for the {@link speak} function.
 */
export type SpeakOptions = {
  /** The text to be spoken. */
  text: string;
  /**
   * Speech rate multiplier. `1.0` is normal speed, `0.5` is half speed, `2.0` is double.
   * On iOS this maps to `AVSpeechUtterance.rate` (0–1 scale internally).
   * On Android this maps to `TextToSpeech.setSpeechRate()`.
   * @default 1.0
   */
  rate?: number;
  /**
   * Pitch multiplier. `1.0` is normal, `0.5` is lower, `2.0` is higher.
   * @default 1.0
   */
  pitch?: number;
  /**
   * BCP-47 language tag, e.g. `"en-US"`, `"ja-JP"`, `"fr-FR"`.
   * If omitted, uses the device default language.
   */
  language?: string;
  /**
   * Platform-specific voice identifier.
   * - **iOS**: `AVSpeechSynthesisVoice.identifier` (e.g. `"com.apple.voice.compact.en-US.Samantha"`).
   * - **Android**: `Voice.getName()` (e.g. `"en-us-x-sfg#male_1-local"`).
   * If provided, overrides `language`.
   */
  voice?: string;
};

/**
 * Options for the {@link synthesizeToFile} function.
 */
export type SynthesizeOptions = {
  /** The text to synthesize to an audio file. */
  text: string;
  /**
   * Absolute file path on the device where the audio will be written.
   * - **iOS**: Writes a `.caf` (Core Audio Format) file with PCM audio.
   * - **Android**: Writes a `.wav` file.
   */
  filePath: string;
  /**
   * Speech rate multiplier. `1.0` is normal speed, `0.5` is half speed, `2.0` is double.
   * @default 1.0
   */
  rate?: number;
  /**
   * Pitch multiplier. `1.0` is normal, `0.5` is lower, `2.0` is higher.
   * @default 1.0
   */
  pitch?: number;
  /**
   * BCP-47 language tag. If omitted, uses the device default.
   */
  language?: string;
  /**
   * Platform-specific voice identifier. Overrides `language` if provided.
   */
  voice?: string;
};

/**
 * Describes an available TTS voice on the device.
 */
export type TtsVoice = {
  /** Platform-specific voice identifier. Pass this to `SpeakOptions.voice`. */
  identifier: string;
  /** Human-readable voice name (e.g. `"Samantha"`, `"Google US English"`). */
  name: string;
  /** BCP-47 language tag this voice supports. */
  language: string;
  /**
   * Voice quality tier.
   * - `"default"` — standard/compact voice
   * - `"enhanced"` — higher quality, larger download (iOS)
   * - `"premium"` — neural/network voice if available
   */
  quality: "default" | "enhanced" | "premium";
};

/**
 * Fired during speech synthesis to report progress.
 */
export type SpeechProgressEvent = {
  /** Character offset of the word currently being spoken. */
  charIndex: number;
  /** Length (in characters) of the word currently being spoken. */
  charLength: number;
};

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

  getVoices(): Promise<TtsVoice[]>;

  stop(): void;

  isSpeaking(): boolean;
};

let NativeLocalTts: LocalTtsModuleType | null = null;

try {
  NativeLocalTts = requireNativeModule<LocalTtsModuleType>("LocalTtsModule");
} catch {
  NativeLocalTts = null;
}

const emitter = NativeLocalTts ? new EventEmitter<Record<string, any>>(NativeLocalTts) : null;

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

// ---------------------------------------------------------------------------
// Public API — File Synthesis
// ---------------------------------------------------------------------------

/**
 * Synthesizes text to an audio file on disk using the device's native TTS
 * engine. The file is written synchronously — the promise resolves once the
 * entire file has been written.
 *
 * - **iOS**: Uses `AVSpeechSynthesizer.write(_:toBufferCallback:)` to capture
 *   PCM buffers, then writes them as a `.caf` audio file via `AVAudioFile`.
 * - **Android**: Uses `TextToSpeech.synthesizeToFile()` which writes a `.wav`.
 *
 * @throws {LocalTtsUnavailableError} If the native module is not installed.
 *
 * @example
 * import * as FileSystem from 'expo-file-system';
 *
 * await synthesizeToFile({
 *   text: "This will be saved to a file",
 *   filePath: `${FileSystem.documentDirectory}speech.caf`,
 *   language: "en-US",
 * });
 */
export async function synthesizeToFile(options: SynthesizeOptions): Promise<void> {
  if (!NativeLocalTts) throw new LocalTtsUnavailableError();
  return NativeLocalTts.synthesizeToFile(normalizeSynthesize(options));
}

// ---------------------------------------------------------------------------
// Public API — Voice Listing
// ---------------------------------------------------------------------------

/**
 * Returns a list of all available TTS voices on the device.
 *
 * @throws {LocalTtsUnavailableError} If the native module is not installed.
 *
 * @example
 * const voices = await getVoices();
 * const englishVoices = voices.filter(v => v.language.startsWith("en"));
 */
export async function getVoices(): Promise<TtsVoice[]> {
  if (!NativeLocalTts) throw new LocalTtsUnavailableError();
  return NativeLocalTts.getVoices();
}

// ---------------------------------------------------------------------------
// Public API — Playback Control
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Public API — Events
// ---------------------------------------------------------------------------

/**
 * Subscribes to word-level progress events during speech.
 *
 * @returns A subscription with a `remove()` method to stop listening.
 *
 * @example
 * const sub = onSpeechProgress((event) => {
 *   console.log(`Speaking char ${event.charIndex}, length ${event.charLength}`);
 * });
 * // Later:
 * sub.remove();
 */
export function onSpeechProgress(
  listener: (event: SpeechProgressEvent) => void
): { remove: () => void } {
  if (!emitter) throw new LocalTtsUnavailableError();
  return emitter.addListener("onSpeechProgress", listener);
}

/**
 * Subscribes to the speech-start event.
 *
 * @returns A subscription with a `remove()` method.
 */
export function onSpeechStart(
  listener: () => void
): { remove: () => void } {
  if (!emitter) throw new LocalTtsUnavailableError();
  return emitter.addListener("onSpeechStart", listener);
}

/**
 * Subscribes to the speech-done event.
 *
 * @returns A subscription with a `remove()` method.
 */
export function onSpeechDone(
  listener: () => void
): { remove: () => void } {
  if (!emitter) throw new LocalTtsUnavailableError();
  return emitter.addListener("onSpeechDone", listener);
}

/**
 * Subscribes to speech error events.
 *
 * @returns A subscription with a `remove()` method.
 */
export function onSpeechError(
  listener: (error: { message: string }) => void
): { remove: () => void } {
  if (!emitter) throw new LocalTtsUnavailableError();
  return emitter.addListener("onSpeechError", listener);
}
