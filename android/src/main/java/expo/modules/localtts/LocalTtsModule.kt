package expo.modules.localtts

import android.media.AudioAttributes
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import android.util.Log
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.records.Field
import expo.modules.kotlin.records.Record
import expo.modules.kotlin.Promise
import java.io.File
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

// ---------------------------------------------------------------------------
// Options Records
// ---------------------------------------------------------------------------

private class SpeakOptions : Record {
  @Field var text: String = ""
  @Field var rate: Double = 1.0
  @Field var pitch: Double = 1.0
  @Field var language: String = ""
  @Field var voice: String = ""
  /** iOS-only; accepted for API parity. */
  @Field var qualityMode: Boolean = true
}

private class SynthesizeOptions : Record {
  @Field var text: String = ""
  @Field var filePath: String = ""
  @Field var rate: Double = 1.0
  @Field var pitch: Double = 1.0
  @Field var language: String = ""
  @Field var voice: String = ""
  /** iOS-only; accepted for API parity. */
  @Field var qualityMode: Boolean = false
}

private class UtteranceSpec : Record {
  @Field var text: String = ""
  @Field var rate: Double = 1.0
  @Field var pitch: Double = 1.0
  @Field var trailingSilenceMs: Double = 0.0
}

private class SynthesizeUtterancesOptions : Record {
  @Field var utterances: ArrayList<UtteranceSpec> = ArrayList()
  @Field var filePath: String = ""
  @Field var language: String = ""
  @Field var voice: String = ""
  @Field var qualityMode: Boolean = false
}

private class ConcatWavOptions : Record {
  @Field var inputPaths: ArrayList<String> = ArrayList()
  @Field var outputPath: String = ""
}

// ---------------------------------------------------------------------------
// Expo Module Definition
// ---------------------------------------------------------------------------

class LocalTtsModule : Module() {
  private val TAG = "LocalTtsModule"
  private var tts: TextToSpeech? = null
  private val initLatch = CountDownLatch(1)
  private var initStatus = TextToSpeech.ERROR

  // Maps utterance IDs → promises so a single global listener can dispatch safely
  private val activePromises = ConcurrentHashMap<String, Promise>()
  private val syncLatches = ConcurrentHashMap<String, CountDownLatch>()
  private val syncErrors = ConcurrentHashMap<String, String>()

  override fun definition() = ModuleDefinition {
    Name("LocalTtsModule")

    Events(
      "onSpeechStart",
      "onSpeechDone",
      "onSpeechError",
      "onSpeechProgress"
    )

    OnCreate {
      val context = appContext.reactContext ?: return@OnCreate
      tts = TextToSpeech(context) { status ->
        initStatus = status
        if (status == TextToSpeech.SUCCESS) {
          Log.d(TAG, "TextToSpeech initialized successfully")

          // Prefer media/speech attributes so engines use higher-fidelity output
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            val audioAttributes = AudioAttributes.Builder()
              .setUsage(AudioAttributes.USAGE_MEDIA)
              .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
              .build()
            tts?.setAudioAttributes(audioAttributes)
          }

          setupGlobalProgressListener()
        } else {
          Log.e(TAG, "TextToSpeech initialization failed with status $status")
        }
        initLatch.countDown()
      }
    }

    // ----- speak -----
    AsyncFunction("speak") { options: SpeakOptions, promise: Promise ->
      ensureInitialized(promise) ?: return@AsyncFunction

      val engine = tts!!
      applyVoiceSettings(engine, options.language, options.voice)
      engine.setSpeechRate(options.rate.toFloat().coerceIn(0.1f, 2.0f))
      engine.setPitch(options.pitch.toFloat().coerceIn(0.5f, 2.0f))

      val utteranceId = "speak-${System.nanoTime()}"
      activePromises[utteranceId] = promise

      val params = Bundle().apply {
        putInt(TextToSpeech.Engine.KEY_PARAM_STREAM, AudioManager.STREAM_MUSIC)
        putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 1.0f)
      }

      val result = engine.speak(options.text, TextToSpeech.QUEUE_FLUSH, params, utteranceId)
      if (result == TextToSpeech.ERROR) {
        activePromises.remove(utteranceId)
        promise.reject("ERR_TTS_SPEAK", "TextToSpeech.speak returned ERROR", null)
      }
    }

    // ----- synthesizeToFile -----
    AsyncFunction("synthesizeToFile") { options: SynthesizeOptions, promise: Promise ->
      ensureInitialized(promise) ?: return@AsyncFunction

      val engine = tts!!
      applyVoiceSettings(engine, options.language, options.voice)
      engine.setSpeechRate(options.rate.toFloat().coerceIn(0.1f, 2.0f))
      engine.setPitch(options.pitch.toFloat().coerceIn(0.5f, 2.0f))

      val utteranceId = "synth-${System.nanoTime()}"
      val outputFile = File(options.filePath)

      // Ensure parent directory exists; overwrite any prior file at this path.
      outputFile.parentFile?.mkdirs()
      if (outputFile.exists()) {
        outputFile.delete()
      }

      if (options.text.isBlank()) {
        promise.reject("ERR_TTS_FILE", "synthesizeToFile requires non-empty text", null)
        return@AsyncFunction
      }

      if (!options.filePath.endsWith(".wav", ignoreCase = true)) {
        promise.reject(
          "ERR_TTS_FILE_PATH",
          "synthesizeToFile requires a .wav filePath",
          null
        )
        return@AsyncFunction
      }

      // Android engines commonly truncate / fail past ~3999 characters per request.
      if (options.text.length > 3999) {
        promise.reject(
          "ERR_TTS_FILE",
          "synthesizeToFile text exceeds Android TTS limit (3999 chars); got ${options.text.length}",
          null
        )
        return@AsyncFunction
      }

      activePromises[utteranceId] = promise

      val params = Bundle().apply {
        putInt(TextToSpeech.Engine.KEY_PARAM_STREAM, AudioManager.STREAM_MUSIC)
        putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 1.0f)
      }

      val result = engine.synthesizeToFile(options.text, params, outputFile, utteranceId)
      if (result == TextToSpeech.ERROR) {
        activePromises.remove(utteranceId)
        promise.reject("ERR_TTS_FILE", "TextToSpeech.synthesizeToFile returned ERROR", null)
      }
    }

    // ----- synthesizeUtterancesToFile -----
    // Streams one chapter WAV by synthesizing parts serially then concatenating
    // on disk (small I/O buffers only — no full-chapter PCM in memory).
    AsyncFunction("synthesizeUtterancesToFile") { options: SynthesizeUtterancesOptions, promise: Promise ->
      ensureInitialized(promise) ?: return@AsyncFunction

      val specs = options.utterances.filter {
        it.text.isNotBlank()
      }
      if (specs.isEmpty()) {
        promise.reject("ERR_TTS_FILE", "synthesizeUtterancesToFile requires non-empty utterances", null)
        return@AsyncFunction
      }
      if (!options.filePath.endsWith(".wav", ignoreCase = true)) {
        promise.reject(
          "ERR_TTS_FILE_PATH",
          "synthesizeUtterancesToFile requires a .wav filePath",
          null
        )
        return@AsyncFunction
      }

      Thread {
        val engine = tts
        if (engine == null) {
          promise.reject("ERR_TTS_INIT", "TextToSpeech engine unavailable", null)
          return@Thread
        }

        val outputFile = File(options.filePath)
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists()) {
          outputFile.delete()
        }

        val partFiles = mutableListOf<File>()
        try {
          applyVoiceSettings(engine, options.language, options.voice)

          for ((index, spec) in specs.withIndex()) {
            if (spec.text.length > 3999) {
              throw IllegalArgumentException(
                "Utterance $index exceeds Android TTS limit (3999 chars); got ${spec.text.length}"
              )
            }

            engine.setSpeechRate(spec.rate.toFloat().coerceIn(0.1f, 2.0f))
            engine.setPitch(spec.pitch.toFloat().coerceIn(0.5f, 2.0f))

            val partFile = File("${options.filePath}.part$index.wav")
            if (partFile.exists()) partFile.delete()

            val utteranceId = "multi-${System.nanoTime()}-$index"
            val latch = CountDownLatch(1)
            syncLatches[utteranceId] = latch
            syncErrors.remove(utteranceId)

            val params = Bundle().apply {
              putInt(TextToSpeech.Engine.KEY_PARAM_STREAM, AudioManager.STREAM_MUSIC)
              putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 1.0f)
            }

            val result = engine.synthesizeToFile(spec.text, params, partFile, utteranceId)
            if (result == TextToSpeech.ERROR) {
              syncLatches.remove(utteranceId)
              throw IllegalStateException("TextToSpeech.synthesizeToFile returned ERROR")
            }

            if (!latch.await(120, TimeUnit.SECONDS)) {
              throw IllegalStateException("synthesizeToFile timed out for utterance $index")
            }
            syncErrors.remove(utteranceId)?.let { throw IllegalStateException(it) }
            if (!partFile.exists() || partFile.length() < 44L) {
              throw IllegalStateException("Empty TTS output for utterance $index")
            }
            partFiles.add(partFile)

            // Trailing silence is approximated by skipping native PCM silence on Android
            // for now; pauses still exist via sentence punctuation in the text.
          }

          concatWavFilesStreaming(partFiles, outputFile)
          val durationSeconds = estimateWavDurationSeconds(outputFile)
          promise.resolve(
            mapOf(
              "durationSeconds" to durationSeconds,
              "sampleRate" to 22050,
              "frameCount" to (durationSeconds * 22050).toInt()
            )
          )
        } catch (e: Exception) {
          Log.e(TAG, "synthesizeUtterancesToFile failed", e)
          promise.reject("ERR_TTS_FILE", e.message ?: "synthesizeUtterancesToFile failed", e)
        } finally {
          for (part in partFiles) {
            part.delete()
          }
        }
      }.start()
    }

    AsyncFunction("concatWavFiles") { options: ConcatWavOptions, promise: Promise ->
      val inputs = options.inputPaths
        .map { it.removePrefix("file://") }
        .filter { it.isNotBlank() }
      val outputPath = options.outputPath.removePrefix("file://")

      if (inputs.isEmpty()) {
        promise.reject("ERR_TTS_CONCAT", "concatWavFiles requires at least one input path", null)
        return@AsyncFunction
      }
      if (!outputPath.endsWith(".wav", ignoreCase = true)) {
        promise.reject("ERR_TTS_CONCAT", "concatWavFiles requires a .wav outputPath", null)
        return@AsyncFunction
      }

      Thread {
        try {
          val outputFile = File(outputPath)
          outputFile.parentFile?.mkdirs()
          if (outputFile.exists()) outputFile.delete()
          concatWavFilesStreaming(inputs.map { File(it) }, outputFile)
          val durationSeconds = estimateWavDurationSeconds(outputFile)
          promise.resolve(
            mapOf(
              "durationSeconds" to durationSeconds,
              "sampleRate" to 22050,
              "frameCount" to (durationSeconds * 22050).toInt()
            )
          )
        } catch (e: Exception) {
          Log.e(TAG, "concatWavFiles failed", e)
          promise.reject("ERR_TTS_CONCAT", e.message ?: "concatWavFiles failed", e)
        }
      }.start()
    }

    // ----- getVoices -----
    AsyncFunction("getVoices") { ->
      ensureInitializedBlocking()
      val engine = tts ?: return@AsyncFunction emptyList<Map<String, Any>>()

      val voices = engine.voices ?: emptySet()
      voices.map { voice ->
        val quality = when (voice.quality) {
          Voice.QUALITY_VERY_HIGH -> "premium"
          Voice.QUALITY_HIGH -> "enhanced"
          else -> "default"
        }
        mapOf(
          "identifier" to voice.name,
          "name" to voice.name,
          "language" to voice.locale.toLanguageTag(),
          "quality" to quality
        )
      }
    }

    // ----- stop -----
    Function("stop") {
      tts?.stop()
      // Prefer onStop for settlement; resolve leftovers engines never callback.
      settleRemainingPromises(resolve = true)
    }

    // ----- isSpeaking -----
    Function("isSpeaking") { ->
      tts?.isSpeaking ?: false
    }

    OnDestroy {
      tts?.stop()
      tts?.shutdown()
      tts = null
      settleRemainingPromises(resolve = false, reason = "Module destroyed")
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  private fun setupGlobalProgressListener() {
    tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
      override fun onStart(id: String?) {
        if (id?.startsWith("speak-") == true) {
          sendEvent("onSpeechStart", emptyMap<String, Any>())
        }
      }

      override fun onDone(id: String?) {
        if (id != null) {
          if (id.startsWith("speak-")) {
            sendEvent("onSpeechDone", emptyMap<String, Any>())
          }
          activePromises.remove(id)?.resolve(null)
          syncLatches.remove(id)?.countDown()
        }
      }

      override fun onStop(utteranceId: String?, interrupted: Boolean) {
        // QUEUE_FLUSH / stop() interrupt prior utterances — settle their promises.
        if (utteranceId != null) {
          if (utteranceId.startsWith("speak-")) {
            sendEvent("onSpeechDone", emptyMap<String, Any>())
          }
          activePromises.remove(utteranceId)?.resolve(null)
          syncLatches.remove(utteranceId)?.countDown()
        }
      }

      @Deprecated("Deprecated in API")
      override fun onError(id: String?) {
        if (id != null) {
          val msg = "Speech error for utterance $id"
          sendEvent("onSpeechError", mapOf("message" to msg))
          activePromises.remove(id)?.reject("ERR_TTS_ENGINE", msg, null)
          syncErrors[id] = msg
          syncLatches.remove(id)?.countDown()
        }
      }

      override fun onError(id: String?, errorCode: Int) {
        if (id != null) {
          val msg = "Speech error code $errorCode for utterance $id"
          sendEvent("onSpeechError", mapOf("message" to msg))
          activePromises.remove(id)?.reject("ERR_TTS_ENGINE", msg, null)
          syncErrors[id] = msg
          syncLatches.remove(id)?.countDown()
        }
      }

      override fun onRangeStart(id: String?, frame: Int, start: Int, end: Int) {
        if (id?.startsWith("speak-") == true) {
          sendEvent("onSpeechProgress", mapOf(
            "charIndex" to start,
            "charLength" to (end - start)
          ))
        }
      }
    })
  }

  private fun settleRemainingPromises(resolve: Boolean, reason: String = "Speech stopped") {
    val ids = activePromises.keys.toList()
    for (id in ids) {
      val promise = activePromises.remove(id) ?: continue
      if (resolve) {
        promise.resolve(null)
      } else {
        promise.reject("ERR_TTS_STOPPED", reason, null)
      }
    }
  }

  /** Waits for TTS init; if it fails, rejects the promise and returns null. */
  private fun ensureInitialized(promise: Promise): Unit? {
    if (!initLatch.await(5, TimeUnit.SECONDS) || initStatus != TextToSpeech.SUCCESS) {
      promise.reject("ERR_TTS_INIT", "TextToSpeech engine failed to initialize", null)
      return null
    }
    return Unit
  }

  /** Blocking version for non-promise functions. */
  private fun ensureInitializedBlocking() {
    initLatch.await(5, TimeUnit.SECONDS)
  }

  /** Applies language and/or voice with explicit setVoice status checking. */
  private fun applyVoiceSettings(engine: TextToSpeech, language: String, voiceName: String) {
    var voiceSet = false

    if (voiceName.isNotEmpty()) {
      val voices = engine.voices ?: emptySet()
      val match = voices.find { it.name == voiceName }
      if (match != null) {
        val status = engine.setVoice(match)
        if (status == TextToSpeech.SUCCESS) {
          voiceSet = true
        } else {
          Log.w(TAG, "engine.setVoice('$voiceName') returned error code $status; falling back to language")
        }
      } else {
        Log.w(TAG, "Requested voice '$voiceName' not found in installed voices; falling back to language")
      }
    }

    if (!voiceSet && language.isNotEmpty()) {
      val locale = Locale.forLanguageTag(language)
      val best = bestVoiceForLocale(engine, locale)
      if (best != null) {
        val status = engine.setVoice(best)
        if (status == TextToSpeech.SUCCESS) {
          voiceSet = true
          Log.d(TAG, "Selected highest-quality voice '${best.name}' (quality=${best.quality}) for $language")
        } else {
          Log.w(TAG, "engine.setVoice('${best.name}') failed with $status; falling back to setLanguage")
        }
      }

      if (!voiceSet) {
        val result = engine.setLanguage(locale)
        if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
          Log.w(TAG, "Language '$language' not supported by engine")
        }
      }
    }
  }

  /**
   * Prefers the highest-quality installed local voice for [locale]
   * (QUALITY_VERY_HIGH > HIGH > NORMAL), excluding network-only voices when
   * an equivalent local voice exists — important for offline audiobook synthesis.
   */
  private fun bestVoiceForLocale(engine: TextToSpeech, locale: Locale): Voice? {
    val voices = engine.voices ?: return null
    val language = locale.language.lowercase()
    val country = locale.country.lowercase()

    fun matches(voice: Voice): Boolean {
      val vl = voice.locale.language.lowercase()
      val vc = voice.locale.country.lowercase()
      if (vl != language) return false
      if (country.isEmpty()) return true
      return vc.isEmpty() || vc == country
    }

    val candidates = voices.filter(::matches)
    if (candidates.isEmpty()) return null

    val local = candidates.filter { !it.isNetworkConnectionRequired }
    val pool = if (local.isNotEmpty()) local else candidates

    return pool.maxWithOrNull(
      compareBy<Voice> { it.quality }
        .thenByDescending { it.latency == Voice.LATENCY_NORMAL || it.latency == Voice.LATENCY_LOW }
    )
  }

  /**
   * Remux PCM from each WAV into a fresh classic 44-byte header.
   * Avoids inheriting nonstandard headers that truncate playback.
   */
  private fun concatWavFilesStreaming(inputs: List<File>, output: File) {
    require(inputs.isNotEmpty()) { "No WAV parts to concatenate" }

    val firstLayout = parseWavPCMLayout(probeWavHeader(inputs[0]))
    val sampleRate = if (firstLayout.sampleRate > 0) firstLayout.sampleRate else 22050
    val bytesPerFrame = firstLayout.bytesPerFrame
    Log.i(
      TAG,
      "concatWav remux pcmOffset=${firstLayout.pcmOffset} rate=$sampleRate parts=${inputs.size}"
    )

    if (output.exists()) output.delete()

    java.io.FileOutputStream(output).use { out ->
      // Placeholder classic header; sizes patched below.
      val header = ByteArray(44)
      header[0] = 'R'.code.toByte(); header[1] = 'I'.code.toByte()
      header[2] = 'F'.code.toByte(); header[3] = 'F'.code.toByte()
      writeIntLEToArray(header, 4, 36)
      header[8] = 'W'.code.toByte(); header[9] = 'A'.code.toByte()
      header[10] = 'V'.code.toByte(); header[11] = 'E'.code.toByte()
      header[12] = 'f'.code.toByte(); header[13] = 'm'.code.toByte()
      header[14] = 't'.code.toByte(); header[15] = ' '.code.toByte()
      writeIntLEToArray(header, 16, 16)
      writeShortLEToArray(header, 20, 1) // PCM
      writeShortLEToArray(header, 22, firstLayout.channels.toShort())
      writeIntLEToArray(header, 24, sampleRate)
      writeIntLEToArray(header, 28, sampleRate * bytesPerFrame)
      writeShortLEToArray(header, 32, bytesPerFrame.toShort())
      writeShortLEToArray(header, 34, firstLayout.bitsPerSample.toShort())
      header[36] = 'd'.code.toByte(); header[37] = 'a'.code.toByte()
      header[38] = 't'.code.toByte(); header[39] = 'a'.code.toByte()
      writeIntLEToArray(header, 40, 0)
      out.write(header)

      for (i in inputs.indices) {
        val partLayout = parseWavPCMLayout(probeWavHeader(inputs[i]))
        java.io.FileInputStream(inputs[i]).use { input ->
          var toSkip = partLayout.pcmOffset.toLong()
          while (toSkip > 0) {
            val skipped = input.skip(toSkip)
            if (skipped <= 0) {
              throw IllegalStateException("Could not seek to PCM in part $i")
            }
            toSkip -= skipped
          }
          val buffer = ByteArray(64 * 1024)
          while (true) {
            val read = input.read(buffer)
            if (read <= 0) break
            out.write(buffer, 0, read)
          }
        }
      }
    }

    val totalSize = output.length()
    val pcmBytes = (totalSize - 44).coerceAtLeast(0)
    java.io.RandomAccessFile(output, "rw").use { raf ->
      raf.seek(4)
      writeIntLE(raf, (36 + pcmBytes).toInt())
      raf.seek(40)
      writeIntLE(raf, pcmBytes.toInt())
    }
  }

  private fun writeIntLEToArray(data: ByteArray, offset: Int, value: Int) {
    data[offset] = (value and 0xff).toByte()
    data[offset + 1] = ((value shr 8) and 0xff).toByte()
    data[offset + 2] = ((value shr 16) and 0xff).toByte()
    data[offset + 3] = ((value shr 24) and 0xff).toByte()
  }

  private fun writeShortLEToArray(data: ByteArray, offset: Int, value: Short) {
    val v = value.toInt()
    data[offset] = (v and 0xff).toByte()
    data[offset + 1] = ((v shr 8) and 0xff).toByte()
  }

  private data class WavPCMLayout(
    val dataSizeFieldOffset: Int,
    val pcmOffset: Int,
    val sampleRate: Int,
    val channels: Int,
    val bitsPerSample: Int,
  ) {
    val bytesPerFrame: Int
      get() = maxOf(1, channels * bitsPerSample / 8)
  }

  private fun probeWavHeader(file: File): ByteArray {
    java.io.FileInputStream(file).use { input ->
      val probe = ByteArray(64 * 1024)
      val read = input.read(probe)
      require(read >= 44) { "WAV file too small: ${file.name}" }
      return probe.copyOf(read)
    }
  }

  private fun readUInt16LE(data: ByteArray, offset: Int): Int {
    return (data[offset].toInt() and 0xff) or ((data[offset + 1].toInt() and 0xff) shl 8)
  }

  private fun readUInt32LE(data: ByteArray, offset: Int): Int {
    return (data[offset].toInt() and 0xff) or
      ((data[offset + 1].toInt() and 0xff) shl 8) or
      ((data[offset + 2].toInt() and 0xff) shl 16) or
      ((data[offset + 3].toInt() and 0xff) shl 24)
  }

  private fun ascii4(data: ByteArray, offset: Int): String {
    if (offset + 4 > data.size) return ""
    return String(data, offset, 4, Charsets.US_ASCII)
  }

  private fun parseWavPCMLayout(data: ByteArray): WavPCMLayout {
    require(ascii4(data, 0) == "RIFF" && ascii4(data, 8) == "WAVE") {
      "Invalid WAV header (missing RIFF/WAVE)"
    }

    var offset = 12
    var sampleRate = 22050
    var channels = 1
    var bitsPerSample = 16

    while (offset + 8 <= data.size) {
      val chunkId = ascii4(data, offset)
      val chunkSize = readUInt32LE(data, offset + 4)
      val payload = offset + 8
      if (chunkSize < 0 || payload > data.size) break

      if (chunkId == "fmt " && chunkSize >= 16 && payload + 16 <= data.size) {
        channels = readUInt16LE(data, payload + 2)
        sampleRate = readUInt32LE(data, payload + 4)
        bitsPerSample = readUInt16LE(data, payload + 14)
      } else if (chunkId == "data") {
        return WavPCMLayout(
          dataSizeFieldOffset = offset + 4,
          pcmOffset = payload,
          sampleRate = if (sampleRate > 0) sampleRate else 22050,
          channels = maxOf(1, channels),
          bitsPerSample = if (bitsPerSample > 0) bitsPerSample else 16,
        )
      }

      offset = payload + chunkSize + (chunkSize and 1)
    }

    throw IllegalStateException("WAV missing data chunk")
  }

  private fun writeIntLE(raf: java.io.RandomAccessFile, value: Int) {
    raf.write(value and 0xff)
    raf.write((value shr 8) and 0xff)
    raf.write((value shr 16) and 0xff)
    raf.write((value shr 24) and 0xff)
  }

  private fun estimateWavDurationSeconds(file: File): Double {
    return try {
      val layout = parseWavPCMLayout(probeWavHeader(file))
      val pcmBytes = (file.length() - layout.pcmOffset).coerceAtLeast(0)
      pcmBytes.toDouble() / layout.bytesPerFrame / layout.sampleRate.toDouble()
    } catch (_: Exception) {
      val bytes = (file.length() - 44).coerceAtLeast(0)
      bytes / 44100.0
    }
  }
}
