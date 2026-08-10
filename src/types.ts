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
   * Platform-specific voice identifier.
   * - **iOS**: `AVSpeechSynthesisVoice.identifier` (e.g. `"com.apple.voice.compact.en-US.Samantha"`).
   * - **Android**: `Voice.getName()` (e.g. `"en-us-x-sfg#male_1-local"`).
   * If provided, overrides `language`.
   */
  voice?: string;
};

/**
 * Options for synthesizing text to an audio file on disk.
 */
export type SynthesizeOptions = {
  /** The text to synthesize to an audio file. */
  text: string;
  /**
   * Absolute filesystem path for the output audio file.
   * Must end with `.wav` (Int16 PCM). The extension selects the container on iOS.
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
export type VoiceInfo = {
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
