package xyz.block.buzz.mobile

import android.speech.tts.TextToSpeech
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SystemTtsCallbackFenceTest {
    @Test
    fun `late completion cannot finish a newer utterance`() {
        val fence = SystemTtsCallbackFence()
        val first = fence.begin(10)
        val second = fence.begin(11)

        assertNull(fence.complete(first))
        assertEquals(11, fence.complete(second))
        assertNull(fence.complete(second))
    }

    @Test
    fun `start lookup identifies only the active utterance`() {
        val fence = SystemTtsCallbackFence()
        val first = fence.begin(10)
        val second = fence.begin(11)

        assertNull(fence.generation(first))
        assertEquals(11, fence.generation(second))
        assertEquals(11, fence.complete(second))
        assertNull(fence.generation(second))
    }

    @Test
    fun `stop invalidates the active utterance`() {
        val fence = SystemTtsCallbackFence()
        val utterance = fence.begin(12)

        fence.invalidate()

        assertNull(fence.complete(utterance))
    }

    @Test
    fun `stop fences speech waiting for engine initialization`() {
        val fence = SystemTtsRequestFence()
        val request = fence.begin()

        fence.invalidate()

        assertFalse(fence.isActive(request))
    }

    @Test
    fun `new speech replaces speech waiting for engine initialization`() {
        val fence = SystemTtsRequestFence()
        val first = fence.begin()
        val second = fence.begin()

        assertFalse(fence.isActive(first))
        assertTrue(fence.isActive(second))
    }

    @Test
    fun `available default language statuses are accepted`() {
        assertTrue(isUsableSystemTtsLanguage(TextToSpeech.LANG_AVAILABLE))
        assertTrue(isUsableSystemTtsLanguage(TextToSpeech.LANG_COUNTRY_AVAILABLE))
        assertTrue(isUsableSystemTtsLanguage(TextToSpeech.LANG_COUNTRY_VAR_AVAILABLE))
        assertFalse(isUsableSystemTtsLanguage(TextToSpeech.LANG_MISSING_DATA))
        assertFalse(isUsableSystemTtsLanguage(TextToSpeech.LANG_NOT_SUPPORTED))
    }

    @Test
    fun `engine initialization and default language must both succeed`() {
        assertTrue(
            isUsableSystemTtsInitialization(
                TextToSpeech.SUCCESS,
                TextToSpeech.LANG_AVAILABLE,
            ),
        )
        assertFalse(
            isUsableSystemTtsInitialization(
                TextToSpeech.ERROR,
                TextToSpeech.LANG_AVAILABLE,
            ),
        )
        assertFalse(
            isUsableSystemTtsInitialization(
                TextToSpeech.SUCCESS,
                TextToSpeech.LANG_NOT_SUPPORTED,
            ),
        )
        assertFalse(isUsableSystemTtsInitialization(TextToSpeech.SUCCESS, null))
    }

    @Test
    fun `only real trim pressure disables Pocket`() {
        assertTrue(
            shouldDisablePocketForTrimMemory(
                TRIM_MEMORY_RUNNING_LOW_LEVEL,
            ),
        )
        assertTrue(
            shouldDisablePocketForTrimMemory(
                TRIM_MEMORY_RUNNING_CRITICAL_LEVEL,
            ),
        )
        assertTrue(
            shouldDisablePocketForTrimMemory(
                TRIM_MEMORY_MODERATE_LEVEL,
            ),
        )
        assertTrue(
            shouldDisablePocketForTrimMemory(
                TRIM_MEMORY_COMPLETE_LEVEL,
            ),
        )
        assertFalse(
            shouldDisablePocketForTrimMemory(
                TRIM_MEMORY_UI_HIDDEN_LEVEL,
            ),
        )
        assertFalse(
            shouldDisablePocketForTrimMemory(
                TRIM_MEMORY_BACKGROUND_LEVEL,
            ),
        )
    }
}
