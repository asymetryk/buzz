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

internal class VoiceAudioOutput(
    context: Context,
    messenger: BinaryMessenger,
) {
    private val applicationContext = context.applicationContext
    private val audioManager =
        applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val channel = MethodChannel(messenger, CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val generation = AtomicInteger()
    private var track: AudioTrack? = null
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

    fun dispose() {
        stop(notify = null)
        channel.setMethodCallHandler(null)
        runCatching { applicationContext.unregisterReceiver(noisyReceiver) }
    }

    private fun handle(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "play" -> {
                val pcm = call.argument<ByteArray>("pcm")
                val sampleRate = call.argument<Int>("sampleRate")
                if (pcm == null || sampleRate == null) {
                    result.error("invalid_arguments", "Expected PCM and sample rate.", null)
                    return
                }
                runCatching { play(pcm, sampleRate) }
                    .onSuccess { result.success(null) }
                    .onFailure {
                        result.error("playback_failed", it.message, null)
                    }
            }
            "stop" -> {
                stop(notify = null)
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

    private fun play(
        pcm: ByteArray,
        sampleRate: Int,
    ) {
        stop(notify = null)
        check(requestFocus()) { "Audio focus was denied." }
        val nextTrack =
            try {
                val attributes =
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
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
                    .setAudioAttributes(attributes)
                    .setAudioFormat(format)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .setBufferSizeInBytes(max(minimum, 32 * 1024))
                    .build()
                    .also {
                        check(it.state == AudioTrack.STATE_INITIALIZED) {
                            "Unable to initialize voice audio."
                        }
                    }
            } catch (error: Exception) {
                abandonFocus()
                throw error
            }
        track = nextTrack
        val currentGeneration = generation.incrementAndGet()
        nextTrack.play()
        thread(name = "buzz-pocket-playback") {
            var offset = 0
            while (offset < pcm.size && generation.get() == currentGeneration) {
                val written = nextTrack.write(
                    pcm,
                    offset,
                    pcm.size - offset,
                    AudioTrack.WRITE_BLOCKING,
                )
                if (written <= 0) break
                offset += written
            }
            val complete = offset == pcm.size
            if (complete) {
                val targetFrames = pcm.size.toLong() / 2
                while (generation.get() == currentGeneration) {
                    val playedFrames =
                        runCatching {
                            nextTrack.playbackHeadPosition.toLong() and 0xFFFF_FFFFL
                        }.getOrNull() ?: break
                    if (playedFrames >= targetFrames) break
                    Thread.sleep(5)
                }
            }
            mainHandler.post {
                if (generation.get() == currentGeneration && track === nextTrack) {
                    nextTrack.stop()
                    nextTrack.release()
                    track = null
                    abandonFocus()
                    channel.invokeMethod(
                        if (complete) "completed" else "error",
                        null,
                    )
                }
            }
        }
    }

    private fun stopAndNotify(event: String) {
        mainHandler.post { stop(notify = event) }
    }

    private fun stop(notify: String?) {
        if (track == null && !hasFocus) return
        generation.incrementAndGet()
        track?.run {
            pause()
            flush()
            stop()
            release()
        }
        track = null
        abandonFocus()
        if (notify != null) channel.invokeMethod(notify, null)
    }

    private fun requestFocus(): Boolean {
        val result =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request =
                    AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                        .setAudioAttributes(
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                .build(),
                        )
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let(audioManager::abandonAudioFocusRequest)
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusListener)
        }
        focusRequest = null
        hasFocus = false
    }

    private companion object {
        const val CHANNEL = "buzz/voice_audio"
    }
}
