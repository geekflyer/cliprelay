package org.cliprelay.service

internal class ClipboardAccessibilityHeuristics(
    private val nowMs: () -> Long = { System.currentTimeMillis() },
    private val toolbarGracePeriodMs: Long = DEFAULT_TOOLBAR_GRACE_PERIOD_MS
) {
    private var copyAffordanceVisible = false
    private var lastCopyAffordanceSeenAtMs = 0L

    fun onCopyAffordanceChanged(hasCopyAffordance: Boolean): Boolean {
        val now = nowMs()
        return if (hasCopyAffordance) {
            copyAffordanceVisible = true
            lastCopyAffordanceSeenAtMs = now
            false
        } else {
            val shouldTrigger = copyAffordanceVisible &&
                now - lastCopyAffordanceSeenAtMs <= toolbarGracePeriodMs
            copyAffordanceVisible = false
            shouldTrigger
        }
    }

    fun resetAfterDirectDetection() {
        copyAffordanceVisible = false
        lastCopyAffordanceSeenAtMs = 0L
    }

    fun containsCopyText(values: Sequence<String>): Boolean {
        return values
            .map(::normalize)
            .filter { it.isNotEmpty() && !it.contains("copyright") }
            .any { normalized -> COPY_WORDS.any { word -> normalized.contains(word) } }
    }

    fun containsCopyConfirmationText(values: Sequence<String>): Boolean {
        return values
            .map(::normalize)
            .filter { it.isNotEmpty() }
            .any { normalized ->
                COPIED_WORDS.any { word -> normalized.contains(word) } ||
                    (normalized.contains("clipboard") && COPY_WORDS.any { word -> normalized.contains(word) })
            }
    }

    private fun normalize(value: String): String {
        return value.lowercase().trim()
    }

    companion object {
        const val DEFAULT_TOOLBAR_GRACE_PERIOD_MS = 1_500L

        val COPY_WORDS = setOf(
            "copy",
            "copy text",
            "copy code",
            "copy link",
            "copy image",
            "copy to clipboard",
            "copiar",
            "copiar texto",
            "copier",
            "kopieren",
            "kopiëren",
            "copia",
            "copiare",
            "コピー",
            "복사",
            "复制",
            "複製",
            "копировать",
            "скопировать",
            "kopyala",
            "คัดลอก",
            "sao chép",
            "salin",
            "kopiuj",
            "skopiuj",
            "kopírovat",
            "kopiera",
            "kopioi",
            "αντιγραφή",
            "העתק",
            "نسخ",
            "कॉपी करें",
        )

        private val COPIED_WORDS = setOf(
            "copied",
            "copied to clipboard",
            "text copied",
            "link copied",
            "copied link",
            "copied text",
            "copied code",
            "copying to clipboard",
        )
    }
}
