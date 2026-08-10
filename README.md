# react-native-local-tts

On-device text-to-speech for React Native. Speaks through the system engines (`AVSpeechSynthesizer` on iOS, `TextToSpeech` on Android), can write Int16 mono WAV files for offline playback, and exposes word-level progress while speaking.

Built as an [Expo module](https://docs.expo.dev/modules/overview/). Works in Expo apps (dev client / production builds) and in bare React Native once Expo modules are installed. **Does not run in Expo Go.**

| | |
| --- | --- |
| Platforms | iOS 13+, Android API 24+ |
| Peer deps | `expo` ≥ 56, `react-native` ≥ 0.78, `react` ≥ 19.2 |
| Output format | `.wav` (Int16 mono PCM) |

---

## Install

### Expo project

```bash
npx expo install react-native-local-tts
```

Or with your usual package manager, then reinstall pods:

```bash
npm install react-native-local-tts
cd ios && pod install && cd ..
```

Rebuild the native app (`npx expo run:ios` / `run:android` or your Xcode / Android Studio flow). Autolinking picks up the module; there is nothing to add to `app.json`.

### Bare React Native (no Expo app workflow)

This package depends on `expo-modules-core`. If your app does not already include Expo modules, add them first:

```bash
npx install-expo-modules@latest
```

That command wires the `expo` package into your iOS and Android projects. If it fails on a heavily customized app, follow Expo’s [manual install guide](https://docs.expo.dev/bare/installing-expo-modules/).

Then install this library and refresh native deps:

```bash
npm install react-native-local-tts
# or: yarn add react-native-local-tts / pnpm add react-native-local-tts

cd ios && pod install && cd ..
```

Rebuild from Xcode / Android Studio (or `npx react-native run-ios` / `run-android`). A Metro reload alone is not enough after the first install — the native module has to be compiled in.

**Quick check** after a successful rebuild:

```ts
import { isAvailable, getVoices } from "react-native-local-tts";

console.log(isAvailable); // true
console.log(await getVoices());
```

If `isAvailable` is `false`, the JS bundle is present but the native binary was not rebuilt (or Expo modules are not linked).

---

## Usage

### Speak

```ts
import { speak, stop, isSpeaking } from "react-native-local-tts";

await speak({
  text: "Hello from the device TTS engine.",
  language: "en-US",
  rate: 1,
  pitch: 1,
});

if (isSpeaking()) {
  stop();
}
```

`speak` resolves when playback finishes (or is stopped), not when it starts.

### Voices

```ts
import { getVoices } from "react-native-local-tts";

const voices = await getVoices();
const premium = voices.find((v) => v.language.startsWith("en") && v.quality === "premium");

await speak({
  text: "Using a specific voice.",
  voice: premium?.identifier,
});
```

Identifiers are platform-specific. Prefer picking from `getVoices()` rather than hard-coding strings across iOS and Android.

### Write a WAV file

Paths should be absolute filesystem paths ending in `.wav`. Strip or keep the `file://` prefix — both are accepted.

```ts
import { synthesizeToFile } from "react-native-local-tts";
import * as FileSystem from "expo-file-system";

const filePath = `${FileSystem.documentDirectory}hello.wav`;

await synthesizeToFile({
  text: "Saved for later playback.",
  filePath,
  language: "en-US",
  // iOS: false favors the faster spoken-audio session path
  qualityMode: false,
});
```

### Long text (multiple utterances → one file)

For chapter-length content, prefer streaming many utterances into one file instead of concatenating in JS:

```ts
import { synthesizeUtterancesToFile } from "react-native-local-tts";

const result = await synthesizeUtterancesToFile({
  filePath: "/path/to/chapter.wav",
  voice: selectedVoiceId,
  qualityMode: true,
  utterances: [
    { text: "First paragraph.", trailingSilenceMs: 400 },
    { text: "Second paragraph.", rate: 1.05, trailingSilenceMs: 600 },
  ],
});

// result.durationSeconds, result.sampleRate, result.frameCount
```

If a single pass is still too large for your timeouts or UX, synthesize batches and stitch them:

```ts
import { concatWavFiles } from "react-native-local-tts";

const { durationSeconds } = await concatWavFiles({
  inputPaths: ["/path/part0.wav", "/path/part1.wav"],
  outputPath: "/path/chapter.wav",
});
```

`concatWavFiles` streams PCM and rewrites the WAV sizes correctly for headers that are not the classic 44-byte layout (common with `AVAudioFile` output).

### Events

```ts
import {
  onSpeechStart,
  onSpeechDone,
  onSpeechProgress,
  onSpeechError,
} from "react-native-local-tts";

const subs = [
  onSpeechStart(() => {}),
  onSpeechDone(() => {}),
  onSpeechProgress(({ charIndex, charLength }) => {
    // highlight text.slice(charIndex, charIndex + charLength)
  }),
  onSpeechError(({ message }) => console.warn(message)),
];

// later
subs.forEach((s) => s.remove());
```

On Android, word progress needs API 26+. Older devices still get start / done / error.

### Hook

```tsx
import { useLocalTts } from "react-native-local-tts";

function SpeakButton() {
  const { speak, stop, isSpeaking, progress, error } = useLocalTts();

  return (
    <>
      <Button
        title={isSpeaking ? "Stop" : "Speak"}
        onPress={() => (isSpeaking ? stop() : speak({ text: "Hi there" }))}
      />
      {progress ? <Text>@{progress.charIndex}</Text> : null}
      {error ? <Text>{error}</Text> : null}
    </>
  );
}
```

---

## API

| Export | Returns | Notes |
| --- | --- | --- |
| `speak(options)` | `Promise<void>` | Live playback |
| `synthesizeToFile(options)` | `Promise<void>` | Single string → one WAV |
| `synthesizeUtterancesToFile(options)` | `Promise<SynthesizeFileResult>` | Many utterances → one WAV |
| `concatWavFiles(options)` | `Promise<SynthesizeFileResult>` | Merge WAV parts on disk |
| `getVoices()` | `Promise<VoiceInfo[]>` | Installed system voices |
| `stop()` | `void` | Stops live speech |
| `isSpeaking()` | `boolean` | Live speech only |
| `isAvailable` | `boolean` | Native module linked |
| `useLocalTts()` | hook | Speech UI state helper |
| `onSpeechStart` / `Done` / `Progress` / `Error` | `{ remove() }` | Event subscriptions |
| `LocalTtsUnavailableError` | class | Thrown when native code is missing |

### Options

**Speak / synthesize shared fields**

| Field | Type | Default | |
| --- | --- | --- | --- |
| `text` | `string` | required | |
| `rate` | `number` | `1` | Relative speed |
| `pitch` | `number` | `1` | Relative pitch |
| `language` | `string` | device default | BCP-47, e.g. `en-GB` |
| `voice` | `string` | — | Overrides `language` when set |
| `qualityMode` | `boolean` | see below | iOS session / mode only |

Defaults for `qualityMode`:

- `speak` → `true` (closer to system Settings playback)
- file APIs → `false` (faster path for bulk conversion)

On iOS, `true` uses `AVAudioSession` mode `.default`; `false` uses `.spokenAudio`. Android ignores the flag.

**`synthesizeUtterancesToFile`**

| Field | Type | |
| --- | --- | --- |
| `utterances` | `{ text, rate?, pitch?, trailingSilenceMs? }[]` | Spoken in order into one file |
| `filePath` | `string` | Absolute `.wav` path |
| `language` / `voice` / `qualityMode` | same as above | Applied to the job |

**`concatWavFiles`**

| Field | Type | |
| --- | --- | --- |
| `inputPaths` | `string[]` | Existing WAV parts, same format |
| `outputPath` | `string` | Destination `.wav` |

**`SynthesizeFileResult`**

`durationSeconds`, `sampleRate`, `frameCount` — metadata only; PCM stays on disk.

**`VoiceInfo`**

`identifier`, `name`, `language`, `quality` (`"default" | "enhanced" | "premium"`).

---

## Platform notes

**iOS**

- Live speech and file write both go through `AVSpeechSynthesizer`.
- File output is Int16 mono WAV via `AVAudioFile`.
- Premium / neural voices can be slow; long jobs use an idle watchdog rather than a short absolute timeout so multi-minute chapters can finish.
- Changing native code in this package always requires a native rebuild.

**Android**

- Uses `android.speech.tts.TextToSpeech`.
- Engine init is async; calls wait briefly for readiness on first use.
- Very long single strings can fail inside the engine — keep utterances under a few thousand characters and batch if needed.

**Both**

- Offline / “enhanced” voices must already be installed by the OS user; this library does not download voice packs.
- `stop()` affects live `speak` playback. In-flight file synthesis is cancelled separately inside the native queue when the module tears a job down.

---

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `LocalTtsUnavailableError` / `isAvailable === false` | App not rebuilt after install, or Expo modules missing in a bare app |
| `synthesizeUtterancesToFile is not available in this native build` | Stale binary — rebuild after upgrading the package |
| Empty or truncated WAV after batching | Upgrade to a build that includes the chunk-aware `concatWavFiles` implementation |
| No word progress on Android | Device below API 26 |
| Sounds different from Settings (iOS) | Try `qualityMode: true` and a premium voice identifier from `getVoices()` |

---

## Development

```bash
npm install
npm run build     # emits dist/
npm run typecheck
```

`main` points at `dist/`. After changing TypeScript, run `build` before the consuming app can see new JS exports. Swift / Kotlin changes still need a native rebuild of the app.

---

## License

MIT. See [LICENSE](LICENSE).
