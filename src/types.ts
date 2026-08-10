/**
 * Shared TypeScript types for react-native-local-tts.
 */

/** Subscription handle returned by event listener helpers. */
export type Subscription = {
  remove: () => void;
};

/**
 * Options for speaking text aloud.
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
   * Platform-specific voice identifier from `getVoices()`.
   * - **iOS**: `AVSpeechSynthesisVoice.identifier` (e.g. `"com.apple.voice.compact.en-US.Samantha"`).
   * - **Android**: `Voice.getName()` (e.g. `"en-us-x-sfg#male_1-local"`).
   * If provided, overrides `language`.
   */
  voice?: string;
  /**
   * iOS audio routing for natural vs faster synthesis.
   * - `true` — `AVAudioSession` `.default` (closer to System Settings / neural voice timbre).
   * - `false` — `.spokenAudio` (usually faster / more compatible for bulk work).
   * No-op on Android.
   * @default true for {@link SpeakOptions} used with `speak()`
   */
  qualityMode?: boolean;
};

/**
 * Options for synthesizing text to an audio file on disk.
 */
export type SynthesizeOptions = {
  /** The text to synthesize to an audio file. */
  text: string;
  /**
   * Absolute filesystem path for the output audio file.
   * Must end with `.wav` (Int16 mono PCM). The `file://` prefix is optional.
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
  /**
   * iOS audio routing for natural vs faster offline synthesis.
   * Same meaning as {@link SpeakOptions.qualityMode}.
   * No-op on Android.
   * @default false for file synthesis APIs
   */
  qualityMode?: boolean;
};

/**
 * One utterance in a streamed multi-utterance synthesis job.
 * Prefer this shape (via `synthesizeUtterancesToFile`) for long text so native
 * code can append silence between segments without holding full-chapter PCM in JS.
 */
export type SynthesizeUtterance = {
  /** Text for this segment. */
  text: string;
  /**
   * Speech rate multiplier for this utterance only.
   * @default 1.0
   */
  rate?: number;
  /**
   * Pitch multiplier for this utterance only.
   * @default 1.0
   */
  pitch?: number;
  /**
   * Silence inserted after this utterance in the same output file, in milliseconds.
   * @default 0
   */
  trailingSilenceMs?: number;
};

/**
 * Options for synthesizing many utterances into a single WAV, streaming to disk.
 * Prefer this for book / chapter conversion — avoids holding full-chapter PCM in JS RAM.
 */
export type SynthesizeUtterancesOptions = {
  /** Segments spoken in order into one file. */
  utterances: SynthesizeUtterance[];
  /**
   * Absolute filesystem path for the output audio file.
   * Must end with `.wav`. The `file://` prefix is optional.
   */
  filePath: string;
  /**
   * BCP-47 language tag applied to the job when `voice` is omitted.
   */
  language?: string;
  /**
   * Platform-specific voice identifier. Overrides `language` if provided.
   */
  voice?: string;
  /**
   * iOS audio routing. Same meaning as {@link SpeakOptions.qualityMode}.
   * @default false
   */
  qualityMode?: boolean;
};

/**
 * Options for streaming-concatenation of Int16 WAV parts into one file.
 * Parses each file’s real `data` chunk (does not assume a classic 44-byte header).
 */
export type ConcatWavOptions = {
  /** Existing WAV part paths, in play order. `file://` prefix is optional. */
  inputPaths: string[];
  /**
   * Absolute destination path ending in `.wav`.
   * `file://` prefix is optional.
   */
  outputPath: string;
};

/**
 * Result metadata from native file synthesis or concat.
 * PCM stays on disk; this is timing / format info only.
 */
export type SynthesizeFileResult = {
  /** Audio length in seconds. */
  durationSeconds: number;
  /** Sample rate of the written PCM (Hz). */
  sampleRate: number;
  /** Total PCM frames written. */
  frameCount: number;
};

/**
 * Describes an available TTS voice on the device.
 */
export type VoiceInfo = {
  /** Platform-specific voice identifier. Pass this to `SpeakOptions.voice`. */
  identifier: string;
  /** Human-readable voice name (e.g. `"Samantha"`, `"Google US English"`). */
  name: string;
  /** BCP-47 language tag this voice supports. */
  language: string;
  /**
   * Voice quality tier.
   * - `"default"` — standard / compact voice
   * - `"enhanced"` — higher quality, larger download (iOS)
   * - `"premium"` — neural / network voice when available
   */
  quality: "default" | "enhanced" | "premium";
};

/** @deprecated Use {@link VoiceInfo}. Kept for backward compatibility. */
export type TtsVoice = VoiceInfo;

/**
 * Fired during speech synthesis to report word-level progress.
 */
export type SpeechProgressEvent = {
  /** Character offset of the word currently being spoken. */
  charIndex: number;
  /** Length (in characters) of the word currently being spoken. */
  charLength: number;
};

/**
 * Payload for speech engine error events.
 */
export type SpeechErrorEvent = {
  message: string;
};

/**
 * Typed event map for the native LocalTts module emitter.
 * Values are listener signatures (Expo `EventsMap` constraint).
 */
export type LocalTtsEvents = {
  onSpeechStart: () => void;
  onSpeechDone: () => void;
  onSpeechProgress: (event: SpeechProgressEvent) => void;
  onSpeechError: (error: SpeechErrorEvent) => void;
};
