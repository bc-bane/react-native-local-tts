# react-native-local-tts

> **Expo module** for local on-device text-to-speech synthesis on iOS and Android — speak text aloud, synthesize to audio files, list available voices, and receive word-level progress events.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Features

- **Speak text aloud** via `AVSpeechSynthesizer` (iOS) and `TextToSpeech` (Android)
- **Synthesize text to audio files** (`.caf` on iOS, `.wav` on Android)
- **List available voices** with quality tiers and language tags
- **Word-level progress events** (`onSpeechProgress`) for live UI updates
- **Speech lifecycle events** — start, done, error
- **React hook** — `useLocalTts()` for progress, synthesis status, and errors
- **Playback control** — `stop()` and `isSpeaking()`
- **Expo SDK 56+ / React Native New Architecture** compatible
- **No Expo Go** required — works with dev clients and standalone builds

---

## Installation

```bash
npm install react-native-local-tts
# or
yarn add react-native-local-tts
```

Autolinking handles native registration — no manual linking required.

> **Note**: This module requires a **dev client** or **standalone build**. It does not work in Expo Go.

### iOS

```bash
cd ios && pod install
```

### Android

No additional setup needed.

---

## Quick Start

```tsx
import { speak, synthesizeToFile, getVoices, stop, isSpeaking } from 'react-native-local-tts';

// Speak text aloud — promise resolves when speech finishes
await speak({
  text: 'Hello, world!',
  language: 'en-US',
  rate: 1.0,
  pitch: 1.0,
});

// Synthesize text to an audio file
await synthesizeToFile({
  text: 'This will be saved to a file.',
  filePath: `${FileSystem.documentDirectory}speech.wav`,
  rate: 1.0,
  pitch: 1.0,
  language: 'en-US',
});

// List available voices
const voices = await getVoices();
const englishVoices = voices.filter(v => v.language.startsWith('en'));
console.log(englishVoices);

// Stop current speech
stop();

// Check if currently speaking
console.log(isSpeaking()); // true or false
```

### React Hook

```tsx
import { useLocalTts } from 'react-native-local-tts';

function Reader() {
  const { speak, synthesizeToFile, isSpeaking, isSynthesizing, progress, error } = useLocalTts();

  return (
    <>
      <Button title={isSpeaking ? 'Speaking…' : 'Speak'} onPress={() => speak({ text: 'Hi' })} />
      <Button
        title={isSynthesizing ? 'Writing…' : 'Save audio'}
        onPress={() =>
          synthesizeToFile({
            text: 'Offline chapter',
            filePath: `${FileSystem.documentDirectory}chapter.caf`,
          })
        }
      />
      {progress ? <Text>Word @ {progress.charIndex}</Text> : null}
      {error ? <Text>{error}</Text> : null}
    </>
  );
}
```

---

## Event Listeners

Subscribe to real-time speech events for building interactive UIs:

```tsx
import { onSpeechStart, onSpeechDone, onSpeechProgress, onSpeechError } from 'react-native-local-tts';

const subs = [
  onSpeechStart(() => console.log('Speech started')),
  onSpeechDone(() => console.log('Speech finished')),
  onSpeechProgress((event) => {
    console.log(`Word at char ${event.charIndex}, length ${event.charLength}`);
  }),
  onSpeechError((err) => console.error('Speech error:', err.message)),
];

// Cleanup
subs.forEach(sub => sub.remove());
```

---

## API Reference

### Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `speak(options)` | `Promise<void>` | Speak text aloud. Resolves when speech finishes. |
| `synthesizeToFile(options)` | `Promise<void>` | Write synthesized speech to an audio file. |
| `getVoices()` | `Promise<VoiceInfo[]>` | List all available TTS voices on the device. |
| `stop()` | `void` | Immediately stop any in-progress speech. |
| `isSpeaking()` | `boolean` | Check if the TTS engine is currently speaking. |
| `isAvailable` | `boolean` | Whether the native module is loaded. |
| `useLocalTts()` | hook state + actions | React hook for speech/synthesis UI state. |

### `SpeakOptions`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `text` | `string` | — | **Required.** Text to speak. |
| `rate` | `number` | `1.0` | Speech rate multiplier (0.5 = half, 2.0 = double). |
| `pitch` | `number` | `1.0` | Pitch multiplier (0.5 = lower, 2.0 = higher). |
| `language` | `string` | device default | BCP-47 language tag (e.g. `"en-US"`). |
| `voice` | `string` | — | Platform-specific voice identifier. Overrides `language`. |

### `SynthesizeOptions`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `text` | `string` | — | **Required.** Text to synthesize. |
| `filePath` | `string` | — | **Required.** Absolute path for the output audio file. |
| `rate` | `number` | `1.0` | Speech rate multiplier (0.5 = half, 2.0 = double). |
| `pitch` | `number` | `1.0` | Pitch multiplier (0.5 = lower, 2.0 = higher). |
| `language` | `string` | device default | BCP-47 language tag. |
| `voice` | `string` | — | Platform-specific voice identifier. |

### `VoiceInfo` (alias: `TtsVoice`)

| Field | Type | Description |
|-------|------|-------------|
| `identifier` | `string` | Voice identifier to pass to `SpeakOptions.voice`. |
| `name` | `string` | Human-readable voice name. |
| `language` | `string` | BCP-47 language tag. |
| `quality` | `"default" \| "enhanced" \| "premium"` | Voice quality tier. |

### Event Subscriptions

| Function | Event Payload | Description |
|----------|--------------|-------------|
| `onSpeechStart(cb)` | `void` | Fires when speech begins. |
| `onSpeechDone(cb)` | `void` | Fires when speech finishes or is cancelled. |
| `onSpeechProgress(cb)` | `{ charIndex, charLength }` | Fires for each word as it's spoken. |
| `onSpeechError(cb)` | `{ message }` | Fires on speech engine errors. |

All event functions return `{ remove: () => void }` to unsubscribe.

---

## Platform Notes

### iOS
- Uses `AVSpeechSynthesizer` for speech and `AVSpeechSynthesizer.write(_:toBufferCallback:)` (iOS 13+) for file synthesis.
- Activates `AVAudioSession` with `.playback` / `.spokenAudio` before synthesis.
- File synthesis writes `.caf` (Core Audio Format) with PCM data via `AVAudioFile`.
- Voice quality tiers map to `AVSpeechSynthesisVoiceQuality` (`.default`, `.enhanced`, `.premium`).

### Android
- Uses `android.speech.tts.TextToSpeech` for speech and `TextToSpeech.synthesizeToFile()` for file synthesis.
- Configures `AudioAttributes` (`USAGE_MEDIA` / `CONTENT_TYPE_SPEECH`) and `STREAM_MUSIC` params.
- File synthesis writes `.wav` files natively.
- Word-level progress requires API 26+ (`onRangeStart`); on older devices only start/done events fire.
- The TTS engine initializes asynchronously on module creation; functions wait up to 5 seconds for initialization.

---

## License

MIT — see [LICENSE](LICENSE) for details.
