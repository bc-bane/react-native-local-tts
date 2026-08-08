package expo.modules.localtts

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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import java.io.File
import java.util.Locale
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
  private val moduleScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private var tts: TextToSpeech? = null
  private val initLatch = CountDownLatch(1)
  private var initStatus = TextToSpeech.ERROR

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
      engine.setSpeechRate(options.rate.toFloat())
      engine.setPitch(options.pitch.toFloat())

      val utteranceId = "speak-${System.nanoTime()}"

      engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
        override fun onStart(id: String?) {
          if (id == utteranceId) {
            sendEvent("onSpeechStart", emptyMap<String, Any>())
          }
        }

        override fun onDone(id: String?) {
          if (id == utteranceId) {
            sendEvent("onSpeechDone", emptyMap<String, Any>())
            promise.resolve(null)
          }
        }

        @Deprecated("Deprecated in API")
        override fun onError(id: String?) {
          if (id == utteranceId) {
            val msg = "Speech error for utterance $id"
            sendEvent("onSpeechError", mapOf("message" to msg))
            promise.reject("ERR_TTS_SPEAK", msg, null)
          }
        }

        override fun onError(id: String?, errorCode: Int) {
          if (id == utteranceId) {
            val msg = "Speech error code $errorCode for utterance $id"
            sendEvent("onSpeechError", mapOf("message" to msg))
            promise.reject("ERR_TTS_SPEAK", msg, null)
          }
        }

        override fun onRangeStart(id: String?, frame: Int, start: Int, end: Int) {
          if (id == utteranceId) {
            sendEvent("onSpeechProgress", mapOf(
              "charIndex" to start,
              "charLength" to (end - start)
            ))
          }
        }
      })

      val params = Bundle()
      engine.speak(options.text, TextToSpeech.QUEUE_FLUSH, params, utteranceId)
    }

    // ----- synthesizeToFile -----
    AsyncFunction("synthesizeToFile") { options: SynthesizeOptions, promise: Promise ->
      ensureInitialized(promise) ?: return@AsyncFunction

      val engine = tts!!
      applyVoiceSettings(engine, options.language, options.voice)
      engine.setSpeechRate(options.rate.toFloat())
      engine.setPitch(options.pitch.toFloat())

      val utteranceId = "synth-${System.nanoTime()}"
      val outputFile = File(options.filePath)

      // Ensure parent directory exists
      outputFile.parentFile?.mkdirs()

      engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
        override fun onStart(id: String?) {}

        override fun onDone(id: String?) {
          if (id == utteranceId) {
            promise.resolve(null)
          }
        }

        @Deprecated("Deprecated in API")
        override fun onError(id: String?) {
          if (id == utteranceId) {
            promise.reject("ERR_TTS_FILE", "Synthesis to file failed for utterance $id", null)
          }
        }

        override fun onError(id: String?, errorCode: Int) {
          if (id == utteranceId) {
            promise.reject("ERR_TTS_FILE", "Synthesis to file failed with error code $errorCode", null)
          }
        }
      })

      val params = Bundle()
      val result = engine.synthesizeToFile(options.text, params, outputFile, utteranceId)
      if (result == TextToSpeech.ERROR) {
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
    }

    // ----- isSpeaking -----
    Function("isSpeaking") { ->
      tts?.isSpeaking ?: false
    }

    OnDestroy {
      tts?.stop()
      tts?.shutdown()
      tts = null
      moduleScope.cancel()
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

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

  /** Applies language and/or voice to the TTS engine. */
  private fun applyVoiceSettings(engine: TextToSpeech, language: String, voiceName: String) {
    // Voice takes precedence over language
    if (voiceName.isNotEmpty()) {
      val voices = engine.voices ?: emptySet()
      val match = voices.find { it.name == voiceName }
      if (match != null) {
        engine.voice = match
        return
      }
      Log.w(TAG, "Requested voice '$voiceName' not found, falling back to language")
    }

    if (language.isNotEmpty()) {
      val locale = Locale.forLanguageTag(language)
      val result = engine.setLanguage(locale)
      if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
        Log.w(TAG, "Language '$language' not supported, using default")
      }
    }
  }
}
