package org.cliprelay.service

// Copyright (c) 2026 Christian T. All Rights Reserved.
// Reference-only source code. See the repository LICENSE for terms.

import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import java.util.Locale

internal class ClipboardAccessibilityHeuristics(
    private val elapsedRealtimeMs: () -> Long = { SystemClock.elapsedRealtime() },
    private val wallClockMs: () -> Long = { System.currentTimeMillis() },
    private val toolbarGracePeriodMs: Long = DEFAULT_TOOLBAR_GRACE_PERIOD_MS,
    private val aggressiveMutationDelayMs: Long = DEFAULT_AGGRESSIVE_MUTATION_DELAY_MS
) {
    private var copyAffordanceVisible = false
    private var lastCopyAffordanceSeenElapsedAtMs = 0L
    private var lastCopyAffordanceSeenWallClockAtMs = 0L

    @Synchronized
    fun onCopyAffordanceChanged(hasCopyAffordance: Boolean): Long? {
        val now = elapsedRealtimeMs()
        return if (hasCopyAffordance) {
            copyAffordanceVisible = true
            lastCopyAffordanceSeenElapsedAtMs = now
            lastCopyAffordanceSeenWallClockAtMs = wallClockMs()
            null
        } else {
            val seenWallClockAtMs = if (
                copyAffordanceVisible &&
                now - lastCopyAffordanceSeenElapsedAtMs <= toolbarGracePeriodMs
            ) {
                lastCopyAffordanceSeenWallClockAtMs
            } else {
                null
            }
            resetToolbarState()
            seenWallClockAtMs
        }
    }

    @Synchronized
    fun resetAfterDirectDetection() {
        resetToolbarState()
    }

    @Synchronized
    fun onWindowsRemoved(windowChanges: Int): Long? {
        if (windowChanges and AccessibilityEvent.WINDOWS_CHANGE_REMOVED == 0) {
            return null
        }

        val now = elapsedRealtimeMs()
        val seenWallClockAtMs = if (
            copyAffordanceVisible &&
            now - lastCopyAffordanceSeenElapsedAtMs <= toolbarGracePeriodMs
        ) {
            lastCopyAffordanceSeenWallClockAtMs
        } else {
            null
        }

        if (seenWallClockAtMs != null) {
            resetToolbarState()
        }
        return seenWallClockAtMs
    }

    @Synchronized
    fun onAggressiveWindowMutation(windowChanges: Int): Long? {
        if (windowChanges and AGGRESSIVE_MUTATION_MASK == 0) {
            return null
        }

        val now = elapsedRealtimeMs()
        val seenWallClockAtMs = if (
            copyAffordanceVisible &&
            now - lastCopyAffordanceSeenElapsedAtMs in aggressiveMutationDelayMs..toolbarGracePeriodMs
        ) {
            lastCopyAffordanceSeenWallClockAtMs
        } else {
            null
        }

        if (seenWallClockAtMs != null) {
            resetToolbarState()
        }
        return seenWallClockAtMs
    }

    fun containsCopyText(values: Sequence<String>): Boolean {
        return values
            .map(::normalize)
            .any(COPY_WORDS::contains)
    }

    fun containsCopyWindowText(values: Sequence<String>): Boolean {
        return values
            .map(::normalize)
            .any(::isCopyAffordanceText)
    }

    fun containsCopyCommandText(values: Sequence<String>): Boolean {
        return containsCopyWindowText(values)
    }

    fun shouldUseConservativeDelayedProbe(packageName: CharSequence?): Boolean {
        val normalizedPackage = packageName?.toString()?.lowercase(Locale.ROOT) ?: return false
        return CONSERVATIVE_DELAYED_PROBE_PACKAGES.contains(normalizedPackage)
    }

    fun debugCopyCandidates(values: Sequence<String>): List<String> {
        return values
            .map(::normalize)
            .filter(::looksCopyRelated)
            .distinct()
            .take(MAX_DEBUG_CANDIDATES)
            .toList()
    }

    private fun normalize(value: String): String {
        return value
            .lowercase(Locale.ROOT)
            .trim()
            .trim { !it.isLetterOrDigit() && !it.isWhitespace() }
            .replace(WHITESPACE_REGEX, " ")
            .trim()
    }

    private fun isCopyAffordanceText(normalized: String): Boolean {
        return COPY_WORDS.contains(normalized) ||
            COPY_COMMAND_PREFIXES.any { prefix ->
                normalized.startsWith("$prefix ") && !normalized.startsWith("$prefix to ")
            }
    }

    private fun looksCopyRelated(normalized: String): Boolean {
        return isCopyAffordanceText(normalized) ||
            COPY_COMMAND_PREFIXES.any { prefix -> normalized.startsWith("$prefix ") }
    }

    private fun resetToolbarState() {
        copyAffordanceVisible = false
        lastCopyAffordanceSeenElapsedAtMs = 0L
        lastCopyAffordanceSeenWallClockAtMs = 0L
    }

    companion object {
        const val DEFAULT_TOOLBAR_GRACE_PERIOD_MS = 1_500L
        const val DEFAULT_AGGRESSIVE_MUTATION_DELAY_MS = 150L
        private const val MAX_DEBUG_CANDIDATES = 4
        private const val AGGRESSIVE_MUTATION_MASK =
            AccessibilityEvent.WINDOWS_CHANGE_CHILDREN or
                AccessibilityEvent.WINDOWS_CHANGE_REMOVED
        private val CONSERVATIVE_DELAYED_PROBE_PACKAGES = setOf(
            "com.reddit.frontpage",
            "com.reddit.frontpage.debug",
        )

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
