package org.cliprelay.service

// Pure text/timing heuristics for auto-copy detection. No Android dependencies
// so the matching rules stay unit-testable on the JVM.

internal object AutoCopyHeuristics {

    /** Clips older than this are treated as "the user did not just copy". */
    const val MAX_CLIP_AGE_MS = 10_000L

    /**
     * Match for "Copy"-style action labels on clicked nodes: either an exact
     * copy word, or a label starting with one ("Copy to clipboard",
     * "Copy message text"). Not a free contains — arbitrary sentences merely
     * mentioning "copy" ("How to copy files") must not fire.
     */
    fun isCopyLabel(text: String): Boolean {
        val normalized = text.lowercase().trim()
        if (normalized.contains("copyright")) return false
        if (normalized in COPY_WORDS) return true
        // "copy of X" is a noun phrase (file listings), not a copy action
        if (normalized.startsWith("copy of ")) return false
        return COPY_PREFIXES.any { normalized.startsWith("$it ") }
    }

    /** Toolbar/window text: any copy word contained (Chrome-style toolbars). */
    fun containsCopyWord(text: String): Boolean {
        val lower = text.lowercase()
        return COPY_WORDS.any { lower.contains(it) }
    }

    /**
     * "Copied to clipboard"-style confirmation toasts. These fire after the
     * clipboard was written, so they are the most reliable copy signal.
     */
    fun isCopiedConfirmation(text: String): Boolean {
        val lower = text.lowercase()
        if (COPYRIGHT_WORDS.any { lower.contains(it) }) return false
        return COPIED_WORDS.any { lower.contains(it) }
    }

    /**
     * Freshness gate for clipboard reads triggered by copy detection: a clip
     * whose timestamp is older than [MAX_CLIP_AGE_MS] predates the detected
     * copy (false positive, e.g. a dismissed toolbar) and must not be sent.
     * Unknown timestamps (null/0 — some OEMs omit them) count as fresh.
     */
    fun isClipFresh(timestampMs: Long?, nowMs: Long): Boolean {
        if (timestampMs == null || timestampMs <= 0L) return true
        return nowMs - timestampMs <= MAX_CLIP_AGE_MS
    }

    // "Copy" (imperative) across locales.
    private val COPY_WORDS = setOf(
        "copy", "copy text",            // English
        "copiar", "copiar texto",       // Spanish, Portuguese
        "copier",                       // French
        "kopieren",                     // German
        "kopiëren",                     // Dutch
        "copia", "copiare",             // Italian
        "コピー",                        // Japanese
        "복사",                          // Korean
        "复制",                          // Chinese (Simplified)
        "複製",                          // Chinese (Traditional)
        "копировать", "скопировать",     // Russian
        "kopyala",                      // Turkish
        "คัดลอก",                       // Thai
        "sao chép",                     // Vietnamese
        "salin",                        // Filipino/Malay/Indonesian
        "kopiuj", "skopiuj",            // Polish
        "kopírovat",                    // Czech
        "kopiera",                      // Swedish
        "kopioi",                       // Finnish
        "αντιγραφή",                    // Greek
        "העתק",                         // Hebrew
        "نسخ",                          // Arabic
        "कॉपी", "कॉपी करें",             // Hindi
        "कॉपी करा",                     // Marathi
        "কপি", "কপি করুন",              // Bengali
        "కాపీ",                         // Telugu
        "நகலெடு", "நகல்",               // Tamil
        "નકલ કરો", "કૉપિ",              // Gujarati
        "ನಕಲು", "ನಕಲಿಸಿ",               // Kannada
        "പകർത്തുക",                     // Malayalam
        "ਕਾਪੀ", "ਕਾਪੀ ਕਰੋ",             // Punjabi
        "କପି",                          // Odia
    )

    // "Copied" (confirmation, matched with contains) across locales.
    private val COPIED_WORDS = setOf(
        "copied",                       // English
        "copiado", "copiada",           // Spanish, Portuguese
        "copié", "copiée",              // French
        "kopiert",                      // German
        "gekopieerd",                   // Dutch
        "copiato", "copiata",           // Italian
        "コピーしました", "コピー済み",     // Japanese
        "복사됨", "복사되었습니다",         // Korean
        "已复制",                        // Chinese (Simplified)
        "已複製",                        // Chinese (Traditional)
        "скопировано",                  // Russian
        "kopyalandı",                   // Turkish
        "คัดลอกแล้ว",                    // Thai
        "đã sao chép",                  // Vietnamese
        "disalin", "tersalin",          // Indonesian/Malay
        "skopiowano",                   // Polish
        "zkopírováno",                  // Czech
        "kopierat", "kopierad",         // Swedish
        "kopioitu",                     // Finnish
        "αντιγράφηκε",                  // Greek
        "הועתק",                        // Hebrew
        "تم النسخ",                     // Arabic
        "कॉपी किया", "कॉपी हो गया",       // Hindi
        "कॉपी केले",                     // Marathi
        "কপি হয়েছে", "কপি করা হয়েছে",    // Bengali
        "కాపీ చేయబడింది",                // Telugu
        "நகலெடுக்கப்பட்டது",              // Tamil
        "નકલ કરી",                      // Gujarati
        "ನಕಲಿಸಲಾಗಿದೆ",                  // Kannada
        "പകർത്തി",                      // Malayalam
        "ਕਾਪੀ ਕੀਤਾ",                    // Punjabi
    )

    // Verb-first languages where "<verb> <object>" labels ("Copy to clipboard",
    // "Texto copiar" doesn't exist — object-first languages stay exact-match).
    private val COPY_PREFIXES = setOf(
        "copy", "copiar", "copier", "kopieren", "kopiëren", "copia", "copiare",
        "копировать", "скопировать", "kopyala", "kopiuj", "skopiuj",
        "kopírovat", "kopiera", "kopioi", "कॉपी",
    )

    private val COPYRIGHT_WORDS = setOf("copyright", "©")
}
