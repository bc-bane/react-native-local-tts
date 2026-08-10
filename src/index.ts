export type {
  LocalTtsEvents,
  SpeakOptions,
  SpeechErrorEvent,
  SpeechProgressEvent,
  Subscription,
  SynthesizeFileResult,
  SynthesizeOptions,
  SynthesizeUtterance,
  SynthesizeUtterancesOptions,
  ConcatWavOptions,
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
  synthesizeUtterancesToFile,
  concatWavFiles,
} from "./LocalTts";

export { useLocalTts } from "./useLocalTts";
export type { UseLocalTtsResult } from "./useLocalTts";
