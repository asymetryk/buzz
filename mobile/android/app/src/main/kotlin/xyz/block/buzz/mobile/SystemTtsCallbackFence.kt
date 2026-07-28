package xyz.block.buzz.mobile

internal class SystemTtsCallbackFence {
    private var sequence = 0L
    private var active: Pair<String, Int>? = null

    fun begin(generation: Int): String {
        val utteranceId = "buzz-system-tts-${++sequence}-$generation"
        active = utteranceId to generation
        return utteranceId
    }

    fun complete(utteranceId: String): Int? {
        val current = active ?: return null
        if (current.first != utteranceId) return null
        active = null
        return current.second
    }

    fun generation(utteranceId: String): Int? {
        val current = active ?: return null
        return current.second.takeIf { current.first == utteranceId }
    }

    fun invalidate() {
        active = null
    }
}

internal class SystemTtsRequestFence {
    private var sequence = 0L
    private var active = 0L

    fun begin(): Long {
        active = ++sequence
        return active
    }

    fun isActive(request: Long): Boolean = active == request

    fun invalidate() {
        active = 0L
    }
}
