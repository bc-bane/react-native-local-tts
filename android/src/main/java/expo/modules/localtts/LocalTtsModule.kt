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
}

private class SynthesizeOptions : Record {
  @Field var text: String = ""
  @Field var filePath: String = ""
  @Field var rate: Double = 1.0
  @Field var pitch: Double = 1.0
  @Field var language: String = ""
  @Field var voice: String = ""
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
        }
      }

      override fun onStop(utteranceId: String?, interrupted: Boolean) {
        // QUEUE_FLUSH / stop() interrupt prior utterances — settle their promises.
        if (utteranceId != null) {
          if (utteranceId.startsWith("speak-")) {
            sendEvent("onSpeechDone", emptyMap<String, Any>())
          }
          activePromises.remove(utteranceId)?.resolve(null)
        }
      }

      @Deprecated("Deprecated in API")
      override fun onError(id: String?) {
        if (id != null) {
          val msg = "Speech error for utterance $id"
          sendEvent("onSpeechError", mapOf("message" to msg))
          activePromises.remove(id)?.reject("ERR_TTS_ENGINE", msg, null)
        }
      }

      override fun onError(id: String?, errorCode: Int) {
        if (id != null) {
          val msg = "Speech error code $errorCode for utterance $id"
          sendEvent("onSpeechError", mapOf("message" to msg))
          activePromises.remove(id)?.reject("ERR_TTS_ENGINE", msg, null)
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
}
