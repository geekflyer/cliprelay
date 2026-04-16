package org.cliprelay.service

// Copyright (c) 2026 Christian T. All Rights Reserved.
// Reference-only source code. See the repository LICENSE for terms.

import android.os.SystemClock
import java.util.Locale

internal class ClipboardAccessibilityHeuristics(
    private val nowMs: () -> Long = { SystemClock.elapsedRealtime() },
    private val toolbarGracePeriodMs: Long = DEFAULT_TOOLBAR_GRACE_PERIOD_MS
) {
    private var copyAffordanceVisible = false
    private var lastCopyAffordanceSeenAtMs = 0L

    @Synchronized
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

    @Synchronized
    fun resetAfterDirectDetection() {
        copyAffordanceVisible = false
        lastCopyAffordanceSeenAtMs = 0L
    }

    @Synchronized
    fun containsCopyText(values: Sequence<String>): Boolean {
        return values
            .map(::normalize)
            .any(COPY_WORDS::contains)
    }

    @Synchronized
    fun containsCopyCommandText(values: Sequence<String>): Boolean {
        return values
            .map(::normalize)
            .any { normalized ->
                COPY_WORDS.contains(normalized) ||
                    COPY_COMMAND_PREFIXES.any { prefix ->
                        normalized.startsWith("$prefix ") && !normalized.startsWith("$prefix to ")
                    }
            }
    }

    private fun normalize(value: String): String {
        return value
            .lowercase(Locale.ROOT)
            .trim()
            .trim { !it.isLetterOrDigit() && !it.isWhitespace() }
            .replace(WHITESPACE_REGEX, " ")
    }

    companion object {
        const val DEFAULT_TOOLBAR_GRACE_PERIOD_MS = 1_500L

        private val WHITESPACE_REGEX = "\\s+".toRegex()

        private val COPY_WORDS = setOf(
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

        private val COPY_COMMAND_PREFIXES = setOf(
            "copy",
            "copiar",
            "copier",
            "kopieren",
            "copia",
            "copiare",
            "копировать",
            "скопировать",
            "kopyala",
            "kopiuj",
            "skopiuj",
            "kopírovat",
            "kopiera",
            "kopioi",
        )
    }
}
