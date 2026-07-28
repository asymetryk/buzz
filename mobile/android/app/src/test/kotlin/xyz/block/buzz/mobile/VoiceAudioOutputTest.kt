package xyz.block.buzz.mobile

import android.media.AudioManager
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class VoiceAudioOutputTest {
    @Test
    fun `all focus losses stop Pocket voice`() {
        assertTrue(shouldStopPocketVoiceForAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS))
        assertTrue(
            shouldStopPocketVoiceForAudioFocusChange(
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            ),
        )
        assertTrue(
            shouldStopPocketVoiceForAudioFocusChange(
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
            ),
        )
    }

    @Test
    fun `focus gain does not interrupt Pocket voice`() {
        assertFalse(shouldStopPocketVoiceForAudioFocusChange(AudioManager.AUDIOFOCUS_GAIN))
    }
}
