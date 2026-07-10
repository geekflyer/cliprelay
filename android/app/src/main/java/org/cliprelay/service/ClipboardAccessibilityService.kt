package org.cliprelay.service

// AccessibilityService that detects copy actions and notifies
// ClipRelayService to read and forward the clipboard.
//
// Detection strategy:
//   1. TYPE_NOTIFICATION_STATE_CHANGED toast containing a localized "copied"
//      confirmation ("Copied to clipboard"). Fires after the clipboard was
//      written, so there is no race with the write — most reliable signal.
//   2. TYPE_VIEW_CLICKED with ACTION_COPY or "Copy" text — works for most apps.
//   3. TYPE_WINDOW_STATE_CHANGED toolbar tracking — catches apps like Chrome
//      that don't fire TYPE_VIEW_CLICKED for their toolbar buttons.
//      When a text action toolbar containing "Copy" appears, we set a flag.
//      When the toolbar closes (next window state change without copy text),
//      we trigger a clipboard read to check if the clipboard was updated.
//      The reader's clip-freshness check filters out toolbars that closed
//      without an actual copy.
//
// Detections are resolved by ClipRelayService via ClipboardOverlayReader
// (a focusable accessibility overlay — no focus steal, closes no system
// dialogs), falling back to ClipboardGhostActivity when unavailable. The
// false-positive gates below still matter: every resolved detection costs a
// clipboard read, and reading a fresh clip shows the system's "ClipRelay
// pasted from your clipboard" banner.

import android.accessibilityservice.AccessibilityService
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import org.cliprelay.BuildConfig
import org.cliprelay.settings.ClipboardSettingsStore

class ClipboardAccessibilityService : AccessibilityService() {

    private lateinit var settingsStore: ClipboardSettingsStore
    private var overlayReader: ClipboardOverlayReader? = null

    // Tracks whether a copy toolbar was recently visible
    @Volatile
    private var copyToolbarVisible = false

    override fun onServiceConnected() {
        super.onServiceConnected()
        settingsStore = ClipboardSettingsStore(this)
        overlayReader = ClipboardOverlayReader(this)
        instance = this
    }

    /**
     * Reads the clipboard via a focusable accessibility overlay window —
     * unlike an activity launch, this closes no system dialogs (notification
     * shade, heads-up, Live Update chips) and keeps the keyboard open.
     * Returns false when the overlay could not even be added; the caller
     * falls back to the ghost activity. [onNeedsGhostFallback] fires later
     * if the overlay was added but never granted window focus.
     */
    fun readClipboardViaOverlay(onNeedsGhostFallback: () -> Unit): Boolean {
        return overlayReader?.start(onNeedsGhostFallback) ?: false
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        // Only process if auto-copy is enabled
        if (!::settingsStore.isInitialized || !settingsStore.isAutoCopyEnabled()) return

        // Disarmed while no Mac is connected — nothing could be forwarded, so
        // skip all scanning/detection work at the source.
        if (!ClipRelayService.anyMacConnected) return

        when (event.eventType) {
            AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED -> handleNotificationEvent(event)
            AccessibilityEvent.TYPE_VIEW_CLICKED -> handleClickEvent(event)
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ->
                if (event.packageName == "com.android.systemui") {
                    handleSystemUiWindow(event)
                } else {
                    handleWindowStateChanged(event)
                }
        }
    }

    // ── System clipboard overlay detection (Android 13+) ─────────────
    //
    // Some apps' copy buttons emit no accessibility events at all (Google
    // Messages' Compose selection toolbar). The only observable signal is the
    // system's "copied" preview overlay: a System UI window event whose text
    // is the copied content. Since notification shade/volume windows also
    // arrive here, only fire when the clipboard was provably written within
    // the last few seconds.

    private fun handleSystemUiWindow(event: AccessibilityEvent) {
        logEventIfDebug("sysui", event)
        if (event.text.all { it.isNullOrBlank() }) return

        // Two accept paths, because System UI also emits shade/volume windows
        // here and a false positive costs the user a visible "ClipRelay pasted
        // from your clipboard" banner:
        //  1. Clipboard metadata timestamp is fresh (works where background
        //     reads of primaryClipDescription are permitted).
        //  2. The window's view IDs are clipboard-specific — AOSP's overlay
        //     uses com.android.systemui:id/clipboard_* (works on Pixel, where
        //     background metadata reads return null).
        val timestampMs = try {
            (getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager)
                ?.primaryClipDescription?.timestamp
        } catch (t: Throwable) {
            null
        }
        val tsFresh = AutoCopyHeuristics.isClipTimestampFresh(timestampMs, System.currentTimeMillis())
        // The shape heuristic alone also matches shade/QS panes ("Notification
        // shade." is a FrameLayout with one text item too), so every shade or
        // heads-up appearance launched the ghost, which steals focus and
        // dismisses the panel along with the keyboard (issue #109). Panes
        // announce themselves with CONTENT_CHANGE_TYPE_PANE_* flags; the
        // clipboard preview overlay's window event carries none (verified on
        // Pixel/A16: shade=32, QS=16, overlay=0).
        val paneFlags = AccessibilityEvent.CONTENT_CHANGE_TYPE_PANE_APPEARED or
            AccessibilityEvent.CONTENT_CHANGE_TYPE_PANE_DISAPPEARED or
            AccessibilityEvent.CONTENT_CHANGE_TYPE_PANE_TITLE
        val shapeMatch = (event.contentChangeTypes and paneFlags) == 0 &&
            AutoCopyHeuristics.looksLikeClipboardOverlay(
                event.className?.toString(),
                event.text.map { it?.toString() }
            )
        val isOverlay = tsFresh || shapeMatch || isClipboardOverlayWindow(event)
        if (BuildConfig.DEBUG) Log.v(TAG, "sysui window: clip ts=$timestampMs overlay=$isOverlay")
        if (!isOverlay) return

        Log.d(TAG, "System clipboard overlay detected")
        copyToolbarVisible = false
        notifyService()
    }

    private fun isClipboardOverlayWindow(event: AccessibilityEvent): Boolean {
        // The overlay usually doesn't attach an event source, so also look the
        // window up by id: AOSP titles it "ClipboardOverlay", and its view IDs
        // are com.android.systemui:id/clipboard_*.
        // nodeTreeHasClipboardId takes ownership of the node and recycles it
        // as part of its scan — recycling here too would double-recycle.
        event.source?.let { source ->
            if (nodeTreeHasClipboardId(source)) return true
        }

        val window = try {
            windows.firstOrNull { it.id == event.windowId }
        } catch (t: Throwable) {
            null
        }
        if (window == null) {
            if (BuildConfig.DEBUG) Log.v(TAG, "sysui window ${event.windowId}: not in windows list")
            return false
        }
        val title = window.title?.toString() ?: ""
        if (BuildConfig.DEBUG) Log.v(TAG, "sysui window ${event.windowId}: title=$title")
        if (title.contains("clipboard", ignoreCase = true)) return true

        val root = window.root ?: return false
        return nodeTreeHasClipboardId(root)
    }

    private fun nodeTreeHasClipboardId(root: AccessibilityNodeInfo): Boolean {
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)
        var inspected = 0
        var found = false
        val seenIds = if (BuildConfig.DEBUG) mutableListOf<String>() else null

        while (queue.isNotEmpty() && inspected < MAX_OVERLAY_SCAN_NODES) {
            val node = queue.removeFirst()
            inspected += 1
            try {
                val id = node.viewIdResourceName
                if (id != null) seenIds?.takeIf { it.size < 8 }?.add(id)
                if (id != null && id.contains("clipboard")) {
                    found = true
                    break
                }
                for (index in 0 until node.childCount) {
                    node.getChild(index)?.let(queue::addLast)
                }
            } finally {
                @Suppress("DEPRECATION")
                node.recycle()
            }
        }

        while (queue.isNotEmpty()) {
            @Suppress("DEPRECATION")
            queue.removeFirst().recycle()
        }
        if (seenIds != null) Log.v(TAG, "scanned ids ($inspected nodes): $seenIds")
        return found
    }

    // ── "Copied" toast detection (most reliable) ─────────────────────

    private fun handleNotificationEvent(event: AccessibilityEvent) {
        logEventIfDebug("toast", event)
        if (event.className != "android.widget.Toast") return
        val text = event.text.joinToString(" ")
        if (AutoCopyHeuristics.isCopiedConfirmation(text)) {
            Log.d(TAG, "Copied-confirmation toast detected")
            copyToolbarVisible = false
            notifyService()
        }
    }

    // ── TYPE_VIEW_CLICKED detection (most apps) ──────────────────────

    private fun handleClickEvent(event: AccessibilityEvent) {
        logEventIfDebug("click", event)

        // Check source node for ACTION_COPY or a copy label/contentDescription.
        // Icon-only toolbar buttons (e.g. Messages' selection bar) carry the
        // label only in the node's contentDescription, never in event.text.
        // Editable fields (EditText) expose ACTION_COPY as an available action
        // merely because they CAN copy a selection — tapping one is focusing,
        // not copying, and the resulting ghost launch closed the keyboard the
        // user just opened (issue #109).
        val source = event.source
        if (source != null) {
            try {
                if ((!source.isEditable && hasActionCopy(source)) || nodeHasCopyLabel(source)) {
                    Log.d(TAG, "Copy action detected on clicked node")
                    copyToolbarVisible = false
                    notifyService()
                    return
                }
            } finally {
                source.recycle()
            }
        }

        // Check event text/contentDescription for "Copy"
        if (isCopyText(event)) {
            Log.d(TAG, "Copy text detected in click event")
            copyToolbarVisible = false
            notifyService()
        }
    }

    // ── TYPE_WINDOW_STATE_CHANGED detection (Chrome, etc.) ───────────

    private fun handleWindowStateChanged(event: AccessibilityEvent) {
        logEventIfDebug("window", event)

        // Keyboard show/hide fires window events too. They must neither arm
        // nor disarm toolbar tracking: a disarm here triggers a pointless
        // clipboard read on every keyboard toggle (issue #109).
        if (isImeWindow(event.windowId)) return

        val text = event.text.joinToString(" ")

        // Icon-only selection toolbars (Messages etc.) expose no window text —
        // fall back to a bounded scan of the active window for a copy button.
        val hasCopyOption = AutoCopyHeuristics.containsCopyWord(text) || windowHasCopyAffordance()

        if (hasCopyOption) {
            // Toolbar with "Copy" option appeared — just note it, don't act yet
            if (!copyToolbarVisible) {
                Log.d(TAG, "Copy toolbar appeared")
            }
            copyToolbarVisible = true
        } else if (copyToolbarVisible) {
            // Toolbar was visible but this window state change doesn't have copy text
            // → toolbar closed (user tapped an option or dismissed it)
            copyToolbarVisible = false

            // Cheap pre-check before paying the clipboard-read cost: where
            // background metadata reads work (e.g. Samsung), a provably stale
            // clip means no copy happened. Unreadable/null timestamps (Pixel)
            // fall through to the reader, whose own freshness check handles
            // them.
            val timestampMs = try {
                (getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager)
                    ?.primaryClipDescription?.timestamp
            } catch (t: Throwable) {
                null
            }
            if (timestampMs != null && timestampMs > 0L &&
                !AutoCopyHeuristics.isClipFresh(timestampMs, System.currentTimeMillis())
            ) {
                Log.d(TAG, "Copy toolbar closed but clip is stale — skipping ghost")
                return
            }

            Log.d(TAG, "Copy toolbar closed → checking clipboard")
            notifyService()
        }
    }

    private fun isListedWindow(windowId: Int): Boolean {
        return try {
            windows.any { it.id == windowId }
        } catch (t: Throwable) {
            false
        }
    }

    private fun isImeWindow(windowId: Int): Boolean {
        val window = try {
            windows.firstOrNull { it.id == windowId }
        } catch (t: Throwable) {
            null
        }
        return window?.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD
    }

    // ── Helpers ──────────────────────────────────────────────────────

    private fun hasActionCopy(node: AccessibilityNodeInfo): Boolean {
        return node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_COPY }
    }

    private fun nodeHasCopyLabel(node: AccessibilityNodeInfo): Boolean {
        node.text?.toString()?.let { if (AutoCopyHeuristics.isCopyLabel(it)) return true }
        node.contentDescription?.toString()?.let { if (AutoCopyHeuristics.isCopyLabel(it)) return true }
        return false
    }

    private fun isCopyText(event: AccessibilityEvent): Boolean {
        if (AutoCopyHeuristics.isCopyLabel(event.text.joinToString(" "))) return true
        val desc = event.contentDescription?.toString() ?: return false
        return AutoCopyHeuristics.isCopyLabel(desc)
    }

    /**
     * Bounded breadth-first scan for a clickable copy button in floating
     * selection toolbars. Only NON-ACTIVE application windows are scanned:
     * selection toolbars are separate popup windows, while the active window
     * is the app's main content — which may legitimately contain persistent
     * "Copy" buttons (GitHub's copy-path/copy-code icons, issue #109) that
     * must not arm toolbar tracking. Breadth-first so shallow toolbar
     * buttons are found before the node budget is spent on deep content.
     */
    private fun windowHasCopyAffordance(): Boolean {
        val roots = try {
            windows.filter {
                it.type == AccessibilityWindowInfo.TYPE_APPLICATION && !it.isActive
            }.mapNotNull { it.root }
        } catch (t: Throwable) {
            emptyList()
        }

        var budget = MAX_WINDOW_SCAN_NODES
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.addAll(roots)
        var found = false

        while (queue.isNotEmpty() && budget > 0) {
            val node = queue.removeFirst()
            budget -= 1
            try {
                if ((node.isClickable || node.isLongClickable) &&
                    (hasActionCopy(node) || nodeHasCopyLabel(node))
                ) {
                    found = true
                    break
                }
                for (index in 0 until node.childCount) {
                    node.getChild(index)?.let(queue::addLast)
                }
            } finally {
                @Suppress("DEPRECATION")
                node.recycle()
            }
        }

        while (queue.isNotEmpty()) {
            @Suppress("DEPRECATION")
            queue.removeFirst().recycle()
        }
        return found
    }

    // Debug builds log every processed event so silent detection misses are
    // diagnosable from `adb logcat -s ClipboardA11y` without a rebuild.
    private fun logEventIfDebug(kind: String, event: AccessibilityEvent) {
        if (!BuildConfig.DEBUG) return
        val desc = event.contentDescription ?: ""
        Log.v(
            TAG,
            "event=$kind pkg=${event.packageName} class=${event.className} " +
                "text=${event.text} desc=$desc full=${event.isFullScreen} " +
                "cct=${event.contentChangeTypes} src=${event.source != null} " +
                "win=${event.windowId} listed=${isListedWindow(event.windowId)}"
        )
    }

    companion object {
        private const val TAG = "ClipboardA11y"
        private const val MAX_WINDOW_SCAN_NODES = 256
        private const val MAX_OVERLAY_SCAN_NODES = 32

        // Same-process handle for ClipRelayService so copy detections can be
        // resolved with an overlay read instead of the ghost activity. Null
        // whenever the accessibility service isn't connected.
        @Volatile
        var instance: ClipboardAccessibilityService? = null
            private set
    }

    private fun notifyService() {
        val intent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_ACCESSIBILITY_COPY_DETECTED
        }
        // Don't crash the accessibility service if the relay service can't be
        // started right now (e.g. background start restrictions) — with no
        // running service there is no session to send to anyway.
        runCatching { startService(intent) }
            .onFailure { Log.w(TAG, "Could not notify ClipRelayService", it) }
    }

    override fun onInterrupt() {
        Log.d(TAG, "Accessibility service interrupted")
    }

    override fun onUnbind(intent: Intent?): Boolean {
        if (instance === this) instance = null
        overlayReader?.cancel()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        overlayReader?.cancel()
        overlayReader = null
        super.onDestroy()
    }
}
