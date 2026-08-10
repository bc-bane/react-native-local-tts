export type {
  LocalTtsEvents,
  SpeakOptions,
  SpeechErrorEvent,
  SpeechProgressEvent,
  Subscription,
  SynthesizeOptions,
  TtsVoice,
  VoiceInfo,
} from "./types";

export {
  LocalTtsUnavailableError,
  getVoices,
  isAvailable,
  isSpeaking,
  onSpeechDone,
  onSpeechError,
  onSpeechProgress,
  onSpeechStart,
  speak,
  stop,
  synthesizeToFile,
} from "./LocalTts";

export { useLocalTts } from "./useLocalTts";
export type { UseLocalTtsResult } from "./useLocalTts";
