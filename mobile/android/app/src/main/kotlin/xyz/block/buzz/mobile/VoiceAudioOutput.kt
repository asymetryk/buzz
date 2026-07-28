package xyz.block.buzz.mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlin.math.max

internal fun shouldStopPocketVoiceForAudioFocusChange(change: Int): Boolean =
    change == AudioManager.AUDIOFOCUS_LOSS ||
        change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT ||
        change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK

internal fun isUsableSystemTtsLanguage(status: Int): Boolean =
    status >= TextToSpeech.LANG_AVAILABLE

internal fun isUsableSystemTtsInitialization(
    initializationStatus: Int,
    languageStatus: Int?,
): Boolean =
    initializationStatus == TextToSpeech.SUCCESS &&
        languageStatus != null &&
        isUsableSystemTtsLanguage(languageStatus)

private data class ActivePlayback(
    val backend: String,
    val generation: Int,
    val utteranceId: String? = null,
)

internal class VoiceAudioOutput(
    context: Context,
    messenger: BinaryMessenger,
    private val requestAudioFocus: (() -> Boolean)? = null,
) {
    private val applicationContext = context.applicationContext
    private val audioManager =
        applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val channel = MethodChannel(messenger, CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val trackGeneration = AtomicInteger()
    private val ttsCallbackFence = SystemTtsCallbackFence()
    private val ttsRequestFence = SystemTtsRequestFence()
    private var track: AudioTrack? = null
    private var textToSpeech: TextToSpeech? = null
    private var ttsInitializationEpoch = 0
    private var ttsInitializing = false
    private val pendingTtsReady = mutableListOf<(TextToSpeech) -> Unit>()
    private val pendingTtsFailure = mutableListOf<(String) -> Unit>()
    private var activePlayback: ActivePlayback? = null
    private var focusRequest: AudioFocusRequest? = null
    private var hasFocus = false
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (shouldStopPocketVoiceForAudioFocusChange(change)) {
            stopAndNotify("interrupted")
        }
    }
    private val noisyReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                stopAndNotify("routeLost")
            }
        }

    init {
        channel.setMethodCallHandler(::handle)
        applicationContext.registerReceiver(
            noisyReceiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
        )
    }

    fun background() {
        mainHandler.post {
            stop(notify = null)
            channel.invokeMethod("backgrounded", null)
        }
    }

    fun foreground() {
        mainHandler.post { channel.invokeMethod("foregrounded", null) }
    }

    fun resourcePressure() {
        mainHandler.post { channel.invokeMethod("resourcePressure", null) }
    }

    fun dispose() {
        stop(notify = null)
        shutdownSystemTts()
        channel.setMethodCallHandler(null)
        runCatching { applicationContext.unregisterReceiver(noisyReceiver) }
    }

    private fun handle(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "play" -> handlePlay(call, result)
            "systemTtsAvailable" -> {
                ensureSystemTts(
                    onReady = { result.success(true) },
                    onFailure = { result.success(false) },
                )
            }
            "speakSystem" -> handleSystemSpeech(call, result)
            "stop" -> {
                stop(notify = null)
                result.success(null)
            }
            "shutdownSystemTts" -> {
                shutdownSystemTts()
                result.success(null)
            }
            "availableCapacity" -> {
                val path = call.arguments as? String
                if (path == null) {
                    result.error("invalid_arguments", "Expected a storage path.", null)
                } else {
                    runCatching { StatFs(path).availableBytes }
                        .onSuccess(result::success)
                        .onFailure { result.error("storage_failed", it.message, null) }
                }
            }
            "excludeFromBackup" -> result.success(null)
            else -> result.notImplemented()
        }
    }

    private fun handlePlay(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val pcm = call.argument<ByteArray>("pcm")
        val sampleRate = call.argument<Int>("sampleRate")
        val generation = call.argument<Int>("generation")
        if (pcm == null || sampleRate == null || generation == null) {
            result.error("invalid_arguments", "Expected PCM, sample rate, and generation.", null)
            return
        }
        runCatching { play(pcm, sampleRate, generation) }
            .onSuccess { result.success(null) }
            .onFailure {
                result.error("playback_failed", it.message, null)
            }
    }

    private fun handleSystemSpeech(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val text = call.argument<String>("text")
        val generation = call.argument<Int>("generation")
        if (text == null || generation == null) {
            result.error("invalid_arguments", "Expected text and generation.", null)
            return
        }
        val request = ttsRequestFence.begin()
        ensureSystemTts(
            onReady = onReady@{ engine ->
                if (!ttsRequestFence.isActive(request)) {
                    result.success(null)
                    return@onReady
                }
                runCatching { speakSystem(engine, text, generation) }
                    .onSuccess { result.success(null) }
                    .onFailure {
                        result.error("system_tts_failed", it.message, null)
                    }
            },
            onFailure = onFailure@{ message ->
                if (!ttsRequestFence.isActive(request)) {
                    result.success(null)
                    return@onFailure
                }
                result.error("system_tts_unavailable", message, null)
            },
        )
    }

    private fun ensureSystemTts(
        onReady: (TextToSpeech) -> Unit,
        onFailure: (String) -> Unit,
    ) {
        textToSpeech?.let {
            onReady(it)
            return
        }
        pendingTtsReady += onReady
        pendingTtsFailure += onFailure
        if (ttsInitializing) return

        ttsInitializing = true
        val epoch = ++ttsInitializationEpoch
        var candidate: TextToSpeech? = null
        try {
            candidate =
                TextToSpeech(applicationContext) { status ->
                    mainHandler.post {
                        val engine = candidate
                        if (epoch != ttsInitializationEpoch) {
                            engine?.shutdown()
                            return@post
                        }
                        if (engine == null) {
                            finishTtsInitializationFailure(
                                "Default text-to-speech engine failed.",
                            )
                            return@post
                        }
                        val languageStatus =
                            if (status == TextToSpeech.SUCCESS) {
                                @Suppress("DEPRECATION")
                                val language = runCatching { engine.language }.getOrNull()
                                language?.let {
                                    runCatching { engine.isLanguageAvailable(it) }.getOrNull()
                                }
                            } else {
                                null
                            }
                        if (!isUsableSystemTtsInitialization(status, languageStatus)) {
                            engine.shutdown()
                            finishTtsInitializationFailure(
                                if (status == TextToSpeech.SUCCESS) {
                                    "Default text-to-speech language is unavailable."
                                } else {
                                    "Default text-to-speech engine failed."
                                },
                            )
                            return@post
                        }
                        engine.setAudioAttributes(speechAudioAttributes())
                        engine.setOnUtteranceProgressListener(ttsProgressListener)
                        textToSpeech = engine
                        ttsInitializing = false
                        val callbacks = pendingTtsReady.toList()
                        pendingTtsReady.clear()
                        pendingTtsFailure.clear()
                        callbacks.forEach { it(engine) }
                    }
                }
        } catch (error: Exception) {
            candidate?.shutdown()
            finishTtsInitializationFailure(
                error.message ?: "Default text-to-speech engine failed.",
            )
        }
    }

    private fun finishTtsInitializationFailure(message: String) {
        ttsInitializing = false
        val callbacks = pendingTtsFailure.toList()
        pendingTtsReady.clear()
        pendingTtsFailure.clear()
        callbacks.forEach { it(message) }
    }

    @Suppress("OVERRIDE_DEPRECATION")
    private val ttsProgressListener =
        object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                if (utteranceId == null) return
                mainHandler.post {
                    val generation = ttsCallbackFence.generation(utteranceId) ?: return@post
                    val active = activePlayback
                    if (active?.utteranceId != utteranceId) return@post
                    notifyFlutter("started", BACKEND_SYSTEM, generation)
                }
            }

            override fun onDone(utteranceId: String?) {
                finishSystemSpeech(utteranceId, successful = true)
            }

            @Deprecated("Deprecated in Android")
            override fun onError(utteranceId: String?) {
                finishSystemSpeech(utteranceId, successful = false)
            }

            override fun onError(
                utteranceId: String?,
                errorCode: Int,
            ) {
                finishSystemSpeech(utteranceId, successful = false)
            }

            override fun onStop(
                utteranceId: String?,
                interrupted: Boolean,
            ) {
                if (!interrupted) finishSystemSpeech(utteranceId, successful = false)
            }
        }

    private fun speakSystem(
        engine: TextToSpeech,
        text: String,
        generation: Int,
    ) {
        stop(notify = null)
        check(requestFocus()) { "Audio focus was denied." }
        val utteranceId = ttsCallbackFence.begin(generation)
        activePlayback = ActivePlayback(BACKEND_SYSTEM, generation, utteranceId)
        val result = engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
        if (result == TextToSpeech.ERROR) {
            ttsCallbackFence.invalidate()
            activePlayback = null
            abandonFocus()
            error("Default text-to-speech engine rejected the utterance.")
        }
    }

    private fun finishSystemSpeech(
        utteranceId: String?,
        successful: Boolean,
    ) {
        if (utteranceId == null) return
        mainHandler.post {
            val generation = ttsCallbackFence.complete(utteranceId) ?: return@post
            val active = activePlayback
            if (active?.utteranceId != utteranceId) return@post
            activePlayback = null
            abandonFocus()
            notifyFlutter(
                if (successful) "completed" else "error",
                BACKEND_SYSTEM,
                generation,
            )
        }
    }

    private fun play(
        pcm: ByteArray,
        sampleRate: Int,
        generation: Int,
    ) {
        stop(notify = null)
        check(requestFocus()) { "Audio focus was denied." }
        val nextTrack =
            try {
                val format =
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                val minimum = AudioTrack.getMinBufferSize(
                    sampleRate,
                    AudioFormat.CHANNEL_OUT_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                )
                AudioTrack.Builder()
                    .setAudioAttributes(speechAudioAttributes())
                    .setAudioFormat(format)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .setBufferSizeInBytes(max(minimum, 32 * 1024))
                    .build()
                    .also {
                        if (it.state != AudioTrack.STATE_INITIALIZED) {
                            it.release()
                            error("Unable to initialize voice audio.")
                        }
                    }
            } catch (error: Exception) {
                abandonFocus()
                throw error
            }
        track = nextTrack
        activePlayback = ActivePlayback(BACKEND_POCKET, generation)
        val currentTrackGeneration = trackGeneration.incrementAndGet()
        try {
            nextTrack.play()
        } catch (error: Exception) {
            track = null
            activePlayback = null
            nextTrack.release()
            abandonFocus()
            throw error
        }
        thread(name = "buzz-pocket-playback") {
            var offset = 0
            var complete = false
            var started = false
            fun reportStartedIfPlaybackAdvanced() {
                if (started || trackGeneration.get() != currentTrackGeneration) return
                val playedFrames =
                    runCatching {
                        nextTrack.playbackHeadPosition.toLong() and 0xFFFF_FFFFL
                    }.getOrNull() ?: return
                if (playedFrames == 0L) return
                started = true
                mainHandler.post {
                    if (
                        trackGeneration.get() == currentTrackGeneration &&
                            track === nextTrack
                    ) {
                        notifyFlutter("started", BACKEND_POCKET, generation)
                    }
                }
            }
            try {
                while (
                    offset < pcm.size &&
                        trackGeneration.get() == currentTrackGeneration
                ) {
                    val written = nextTrack.write(
                        pcm,
                        offset,
                        pcm.size - offset,
                        AudioTrack.WRITE_BLOCKING,
                    )
                    if (written <= 0) break
                    offset += written
                    reportStartedIfPlaybackAdvanced()
                }
                complete = offset == pcm.size
                if (complete) {
                    val targetFrames = pcm.size.toLong() / 2
                    val deadlineNanos =
                        System.nanoTime() +
                            (targetFrames * 1_000_000_000L / sampleRate) +
                            2_000_000_000L
                    var drained = false
                    while (
                        trackGeneration.get() == currentTrackGeneration &&
                            System.nanoTime() < deadlineNanos
                    ) {
                        val playedFrames =
                            runCatching {
                                nextTrack.playbackHeadPosition.toLong() and 0xFFFF_FFFFL
                            }.getOrNull() ?: break
                        reportStartedIfPlaybackAdvanced()
                        if (playedFrames >= targetFrames) {
                            drained = true
                            break
                        }
                        Thread.sleep(5)
                    }
                    complete = drained
                }
            } catch (_: Exception) {
                complete = false
            }
            mainHandler.post {
                if (
                    trackGeneration.get() == currentTrackGeneration &&
                        track === nextTrack
                ) {
                    releaseTrack(nextTrack)
                    track = null
                    val active = activePlayback
                    activePlayback = null
                    abandonFocus()
                    notifyFlutter(
                        if (complete) "completed" else "error",
                        BACKEND_POCKET,
                        active?.generation ?: generation,
                    )
                }
            }
        }
    }

    private fun stopAndNotify(event: String) {
        mainHandler.post { stop(notify = event) }
    }

    private fun stop(notify: String?) {
        val active = activePlayback
        ttsRequestFence.invalidate()
        trackGeneration.incrementAndGet()
        track?.let(::releaseTrack)
        track = null
        ttsCallbackFence.invalidate()
        runCatching { textToSpeech?.stop() }
        activePlayback = null
        abandonFocus()
        if (notify != null && active != null) {
            notifyFlutter(notify, active.backend, active.generation)
        }
    }

    private fun shutdownSystemTts() {
        ttsInitializationEpoch += 1
        ttsInitializing = false
        pendingTtsReady.clear()
        val failures = pendingTtsFailure.toList()
        pendingTtsFailure.clear()
        failures.forEach { it("Default text-to-speech engine was shut down.") }
        ttsCallbackFence.invalidate()
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
    }

    private fun requestFocus(): Boolean {
        requestAudioFocus?.let {
            hasFocus = it()
            return hasFocus
        }
        val result =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request =
                    AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                        .setAudioAttributes(speechAudioAttributes())
                        .setOnAudioFocusChangeListener(focusListener, mainHandler)
                        .build()
                focusRequest = request
                audioManager.requestAudioFocus(request)
            } else {
                @Suppress("DEPRECATION")
                audioManager.requestAudioFocus(
                    focusListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
                )
            }
        hasFocus = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        return hasFocus
    }

    private fun abandonFocus() {
        if (!hasFocus) return
        if (requestAudioFocus != null) {
            hasFocus = false
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let(audioManager::abandonAudioFocusRequest)
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusListener)
        }
        focusRequest = null
        hasFocus = false
    }

    private fun releaseTrack(audioTrack: AudioTrack) {
        runCatching { audioTrack.pause() }
        runCatching { audioTrack.flush() }
        runCatching { audioTrack.stop() }
        runCatching { audioTrack.release() }
    }

    private fun notifyFlutter(
        method: String,
        backend: String,
        generation: Int,
    ) {
        channel.invokeMethod(
            method,
            mapOf("backend" to backend, "generation" to generation),
        )
    }

    private fun speechAudioAttributes(): AudioAttributes =
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()

    private companion object {
        const val CHANNEL = "buzz/voice_audio"
        const val BACKEND_POCKET = "pocket"
        const val BACKEND_SYSTEM = "androidSystem"
    }
}
