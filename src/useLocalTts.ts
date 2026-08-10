import { useCallback, useEffect, useRef, useState } from "react";
import {
  getVoices,
  isAvailable,
  isSpeaking as nativeIsSpeaking,
  onSpeechDone,
  onSpeechError,
  onSpeechProgress,
  onSpeechStart,
  speak as nativeSpeak,
  stop as nativeStop,
  synthesizeToFile as nativeSynthesizeToFile,
} from "./LocalTts";
import type {
  SpeakOptions,
  SpeechErrorEvent,
  SpeechProgressEvent,
  SynthesizeOptions,
  VoiceInfo,
} from "./types";

export type UseLocalTtsResult = {
  /** Whether the native module is loaded on this build. */
  isAvailable: boolean;
  /** True while real-time speech playback is in progress. */
  isSpeaking: boolean;
  /** True while an offline `synthesizeToFile` call is in flight. */
  isSynthesizing: boolean;
  /** Latest word-level progress event, or `null` before the first update. */
  progress: SpeechProgressEvent | null;
  /** Last error message from speech events or thrown API calls. */
  error: string | null;
  /** Speak text aloud. Resolves when playback finishes or is stopped. */
  speak: (options: SpeakOptions) => Promise<void>;
  /** Synthesize text to an audio file on disk. */
  synthesizeToFile: (options: SynthesizeOptions) => Promise<void>;
  /** List installed TTS voices. */
  getVoices: () => Promise<VoiceInfo[]>;
  /** Stop in-progress speech immediately. */
  stop: () => void;
  /** Clear the hook-managed error state. */
  clearError: () => void;
};

/**
 * React hook that wires speech lifecycle events and synthesis status into
 * local component state.
 *
 * Subscribes to start / done / progress / error while the component is mounted.
 * Useful for simple speak buttons and progress UI; for batch file conversion
 * prefer calling `synthesizeUtterancesToFile` / `concatWavFiles` directly.
 *
 * @example
 * ```tsx
 * const { speak, isSpeaking, progress, synthesizeToFile, isSynthesizing } = useLocalTts();
 *
 * await speak({ text: "Hello", language: "en-US" });
 * ```
 */
export function useLocalTts(): UseLocalTtsResult {
  const [speaking, setSpeaking] = useState(false);
  const [isSynthesizing, setIsSynthesizing] = useState(false);
  const [progress, setProgress] = useState<SpeechProgressEvent | null>(null);
  const [error, setError] = useState<string | null>(null);
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;

    if (!isAvailable) {
      return () => {
        mountedRef.current = false;
      };
    }

    const subs = [
      onSpeechStart(() => {
        if (!mountedRef.current) return;
        setSpeaking(true);
        setError(null);
        setProgress(null);
      }),
      onSpeechDone(() => {
        if (!mountedRef.current) return;
        setSpeaking(false);
      }),
      onSpeechProgress((event: SpeechProgressEvent) => {
        if (!mountedRef.current) return;
        setProgress(event);
      }),
      onSpeechError((event: SpeechErrorEvent) => {
        if (!mountedRef.current) return;
        setError(event.message);
        setSpeaking(false);
      }),
    ];

    return () => {
      mountedRef.current = false;
      subs.forEach((sub) => sub.remove());
    };
  }, []);

  const speak = useCallback(async (options: SpeakOptions) => {
    setError(null);
    try {
      await nativeSpeak(options);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      if (mountedRef.current) {
        setError(message);
        setSpeaking(false);
      }
      throw err;
    }
  }, []);

  const synthesizeToFile = useCallback(async (options: SynthesizeOptions) => {
    setError(null);
    if (mountedRef.current) setIsSynthesizing(true);
    try {
      await nativeSynthesizeToFile(options);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      if (mountedRef.current) setError(message);
      throw err;
    } finally {
      if (mountedRef.current) setIsSynthesizing(false);
    }
  }, []);

  const stop = useCallback(() => {
    nativeStop();
    if (mountedRef.current) setSpeaking(false);
  }, []);

  const clearError = useCallback(() => {
    setError(null);
  }, []);

  const listVoices = useCallback(async () => {
    return getVoices();
  }, []);

  return {
    isAvailable,
    isSpeaking: speaking || (isAvailable ? nativeIsSpeaking() : false),
    isSynthesizing,
    progress,
    error,
    speak,
    synthesizeToFile,
    getVoices: listVoices,
    stop,
    clearError,
  };
}
