package xyz.block.buzz.mobile

import android.speech.tts.TextToSpeech
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SystemTextToSpeechInstrumentedTest {
    @Test
    fun installedDefaultEngineInitializesWithItsDefaultLanguage() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val initialized = CountDownLatch(1)
        val status = AtomicInteger(TextToSpeech.ERROR)
        lateinit var engine: TextToSpeech

        engine =
            TextToSpeech(context) {
                status.set(it)
                initialized.countDown()
            }
        try {
            assertTrue(initialized.await(20, TimeUnit.SECONDS))
            assertEquals(TextToSpeech.SUCCESS, status.get())
            assertNotNull(engine.defaultEngine)
            @Suppress("DEPRECATION")
            val language = assertNotNull(engine.language)
            assertTrue(isUsableSystemTtsLanguage(engine.isLanguageAvailable(language)))
        } finally {
            engine.stop()
            engine.shutdown()
        }
    }

    @Test
    fun voiceBoundarySpeaksAndCancelsWithGenerationFencedCallbacks() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val messenger = RecordingBinaryMessenger()
        // Instrumentation has no foreground Activity, so Android 15 rejects
        // real audio-focus requests. Exercise the real default TTS engine while
        // keeping focus behavior covered by the deterministic JVM tests.
        val output = VoiceAudioOutput(context, messenger, requestAudioFocus = { true })
        try {
            assertEquals(true, messenger.call("systemTtsAvailable"))
            assertNull(
                messenger.call(
                    "speakSystem",
                    mapOf(
                        "text" to "Buzz Android system speech fallback is ready.",
                        "generation" to 41,
                    ),
                ),
            )
            val completed = messenger.awaitOutgoing("completed", generation = 41)
            assertEquals("androidSystem", completed.argumentsMap["backend"])

            messenger.call(
                "speakSystem",
                mapOf(
                    "text" to
                        List(12) { "This sentence should be cancelled." }.joinToString(" "),
                    "generation" to 42,
                ),
            )
            messenger.call("stop")
            Thread.sleep(500)
            assertNull(
                messenger.findOutgoing("completed", generation = 42),
                "stop must fence a late TextToSpeech completion",
            )
        } finally {
            output.dispose()
        }
    }
}

private class RecordingBinaryMessenger : BinaryMessenger {
    private val codec = StandardMethodCodec.INSTANCE
    private val outgoing = CopyOnWriteArrayList<MethodCall>()
    private var handler: BinaryMessenger.BinaryMessageHandler? = null

    override fun send(
        channel: String,
        message: ByteBuffer?,
    ) {
        recordOutgoing(channel, message)
    }

    override fun send(
        channel: String,
        message: ByteBuffer?,
        callback: BinaryMessenger.BinaryReply?,
    ) {
        recordOutgoing(channel, message)
        callback?.reply(codec.encodeSuccessEnvelope(null))
    }

    override fun setMessageHandler(
        channel: String,
        handler: BinaryMessenger.BinaryMessageHandler?,
    ) {
        if (channel == VOICE_CHANNEL) this.handler = handler
    }

    fun call(
        method: String,
        arguments: Any? = null,
    ): Any? {
        val completed = CountDownLatch(1)
        val value = AtomicReference<Any?>()
        val failure = AtomicReference<Throwable?>()
        val message = codec.encodeMethodCall(MethodCall(method, arguments)).forReading()
        val registered = checkNotNull(handler)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            registered.onMessage(message) { reply ->
                try {
                    value.set(reply?.forReading()?.let(codec::decodeEnvelope))
                } catch (error: Throwable) {
                    failure.set(error)
                } finally {
                    completed.countDown()
                }
            }
        }
        assertTrue(completed.await(20, TimeUnit.SECONDS))
        failure.get()?.let { throw it }
        return value.get()
    }

    fun awaitOutgoing(
        method: String,
        generation: Int,
    ): MethodCall {
        repeat(200) {
            findOutgoing(method, generation)?.let { return it }
            Thread.sleep(50)
        }
        error("Timed out waiting for $method generation $generation")
    }

    fun findOutgoing(
        method: String,
        generation: Int,
    ): MethodCall? =
        outgoing.firstOrNull {
            it.method == method && it.argumentsMap["generation"] == generation
        }

    private fun recordOutgoing(
        channel: String,
        message: ByteBuffer?,
    ) {
        if (channel == VOICE_CHANNEL && message != null) {
            outgoing += codec.decodeMethodCall(message.forReading())
        }
    }

    private companion object {
        const val VOICE_CHANNEL = "buzz/voice_audio"
    }
}

private val MethodCall.argumentsMap: Map<*, *>
    get() = arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()

private fun ByteBuffer.forReading(): ByteBuffer =
    duplicate().also {
        if (it.position() == 0) {
            it.rewind()
        } else {
            it.flip()
        }
    }
