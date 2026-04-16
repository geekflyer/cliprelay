package org.cliprelay.service

// AccessibilityService that detects copy actions and notifies
// ClipRelayService to read and forward the clipboard.
//
// Detection strategy:
//   1. TYPE_VIEW_CLICKED with ACTION_COPY or "Copy" text — works for most apps.
//   2. TYPE_WINDOW_STATE_CHANGED toolbar tracking — catches apps like Chrome
//      that don't fire TYPE_VIEW_CLICKED for their toolbar buttons.
//      When a text action toolbar containing "Copy" appears, we set a flag.
//      When the toolbar closes (next window state change without copy text),
//      we launch the ghost activity to check if the clipboard was updated.
//      This avoids stealing focus while the toolbar is still visible.

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.cliprelay.BuildConfig
import org.cliprelay.settings.ClipboardSettingsStore
import java.util.concurrent.atomic.AtomicLong

class ClipboardAccessibilityService : AccessibilityService() {

    private lateinit var settingsStore: ClipboardSettingsStore
    private val heuristics = ClipboardAccessibilityHeuristics()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingWindowProbe: Runnable? = null
    private val windowProbeToken = AtomicLong(0L)

    override fun onServiceConnected() {
        super.onServiceConnected()
        settingsStore = ClipboardSettingsStore(this)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        // Only process if auto-copy is enabled
        if (!::settingsStore.isInitialized || !settingsStore.isAutoCopyEnabled()) return
        val aggressiveMode = settingsStore.isAggressiveAutoCopyEnabled()

        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED -> handleClickEvent(event)
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOWS_CHANGED -> handleWindowChangeEvent(event, aggressiveMode)
        }
    }

    // ── TYPE_VIEW_CLICKED detection (most apps) ──────────────────────

    private fun handleClickEvent(event: AccessibilityEvent) {
        val matched = eventMatchesCopy(event)
        if (matched) {
            cancelWindowProbe()
            triggerCopyDetected("click", ClipRelayService.CLIPBOARD_TRIGGER_DIRECT)
        } else {
            logPotentialMissIfDebug("click", event)
        }
    }

    // ── TYPE_WINDOW_STATE_CHANGED detection (Chrome, etc.) ───────────

    private fun handleWindowChangeEvent(event: AccessibilityEvent, aggressiveMode: Boolean) {
        if (aggressiveMode) {
            val removedWindowSeenAtMs = heuristics.onWindowsRemoved(event.windowChanges)
            if (removedWindowSeenAtMs != null) {
                cancelWindowProbe()
                if (BuildConfig.DEBUG) {
                    Log.d(
                        TAG,
                        "Aggressive removal trigger: type=${eventTypeName(event.eventType)} " +
                            "windowChanges=${event.windowChanges}"
                    )
                }
                triggerCopyDetected(
                    "${eventTypeName(event.eventType)} removed",
                    ClipRelayService.CLIPBOARD_TRIGGER_TOOLBAR_CLOSE,
                    minClipboardTimestampMs = removedWindowSeenAtMs
                )
                return
            }

            val mutationSeenAtMs = heuristics.onAggressiveWindowMutation(event.windowChanges)
            if (mutationSeenAtMs != null) {
                cancelWindowProbe()
                if (BuildConfig.DEBUG) {
                    Log.d(
                        TAG,
                        "Aggressive mutation trigger: type=${eventTypeName(event.eventType)} " +
                            "windowChanges=${event.windowChanges}"
                    )
                }
                triggerCopyDetected(
                    "${eventTypeName(event.eventType)} mutation",
                    ClipRelayService.CLIPBOARD_TRIGGER_TOOLBAR_CLOSE,
                    minClipboardTimestampMs = mutationSeenAtMs
                )
                return
            }
        }

        val hasCopyAffordance = hasWindowCopyAffordance(event, aggressiveMode)
        val affordanceSeenAtMs = heuristics.onCopyAffordanceChanged(hasCopyAffordance)
        if (affordanceSeenAtMs != null) {
            cancelWindowProbe()
            triggerCopyDetected(
                "${eventTypeName(event.eventType)} close",
                ClipRelayService.CLIPBOARD_TRIGGER_TOOLBAR_CLOSE,
                minClipboardTimestampMs = affordanceSeenAtMs
            )
        } else if (hasCopyAffordance) {
            Log.d(TAG, "Copy affordance visible via ${eventTypeName(event.eventType)}")
            if (aggressiveMode || heuristics.shouldUseConservativeDelayedProbe(event.packageName)) {
                scheduleWindowProbe(event)
            }
        } else {
            cancelWindowProbe()
            logPotentialMissIfDebug("window_state", event)
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────

    private fun eventMatchesCopy(event: AccessibilityEvent): Boolean {
        val source = event.source
        if (source != null) {
            try {
                if (nodeMatchesCopy(source)) {
                    return true
                }
            } finally {
                source.recycle()
            }
        }
        return heuristics.containsCopyCommandText(eventSignals(event))
    }

    private fun nodeMatchesCopy(node: AccessibilityNodeInfo): Boolean {
        if (node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_COPY }) {
            return true
        }

        return heuristics.containsCopyCommandText(nodeSignals(node))
    }

    private fun eventSignals(event: AccessibilityEvent): Sequence<String> {
        val eventText = event.text.asSequence().map { it.toString() }
        val contentDescription = sequenceOf(event.contentDescription?.toString()).filterNotNull()
        return eventText + contentDescription
    }

    private fun nodeSignals(node: AccessibilityNodeInfo): Sequence<String> {
        val nodeText = sequenceOf(node.text?.toString()).filterNotNull()
        val contentDescription = sequenceOf(node.contentDescription?.toString()).filterNotNull()
        val actionLabels = node.actionList.asSequence().mapNotNull { it.label?.toString() }
        return nodeText + contentDescription + actionLabels
    }

    private fun windowStateSignals(event: AccessibilityEvent): Sequence<String> {
        val signals = mutableListOf<String>()
        signals += event.text.map { it.toString() }
        event.contentDescription?.toString()?.let(signals::add)

        val source = event.source
        if (source != null) {
            try {
                signals += nodeSignals(source).toList()
            } finally {
                source.recycle()
            }
        }

        return signals.asSequence()
    }

    private fun hasWindowCopyAffordance(event: AccessibilityEvent, aggressiveMode: Boolean): Boolean {
        val windowSignals = windowStateSignals(event).toList()
        if (heuristics.containsCopyWindowText(windowSignals.asSequence())) {
            logWindowSignalsIfDebug("event", event, windowSignals)
            return true
        }

        val root = rootInActiveWindow ?: return false
        return activeWindowHasCopyAffordance(root, aggressiveMode, event)
    }

    private fun activeWindowHasCopyAffordance(
        root: AccessibilityNodeInfo,
        aggressiveMode: Boolean,
        event: AccessibilityEvent
    ): Boolean {
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)
        var inspectedNodes = 0

        while (queue.isNotEmpty() && inspectedNodes < MAX_WINDOW_SCAN_NODES) {
            val node = queue.removeFirst()
            try {
                inspectedNodes += 1
                if (node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_COPY }) {
                    logRootMatchIfDebug(event, "action_copy", nodeSignals(node).toList())
                    recycleQueue(queue)
                    return true
                }
                val nodeSignals = nodeSignals(node).toList()
                if (nodeHasActionableCopyLabel(node, nodeSignals, aggressiveMode, event)) {
                    recycleQueue(queue)
                    return true
                }

                val childCount = node.childCount
                for (index in 0 until childCount) {
                    node.getChild(index)?.let(queue::addLast)
                }
            } finally {
                node.recycle()
            }
        }

        recycleQueue(queue)
        return false
    }

    private fun nodeHasActionableCopyLabel(
        node: AccessibilityNodeInfo,
        nodeSignals: List<String>,
        aggressiveMode: Boolean,
        event: AccessibilityEvent
    ): Boolean {
        if (!heuristics.containsCopyWindowText(nodeSignals.asSequence())) {
            return false
        }

        if (aggressiveMode) {
            logRootMatchIfDebug(event, "aggressive_text", nodeSignals)
            return true
        }

        if (isActionableNode(node)) {
            logRootMatchIfDebug(event, "node_actionable", nodeSignals)
            return true
        }

        var currentParent = node.parent
        var depth = 0
        while (currentParent != null && depth < MAX_ACTIONABLE_ANCESTOR_DEPTH) {
            val parent = currentParent
            if (isActionableNode(parent)) {
                logRootMatchIfDebug(event, "ancestor_actionable_$depth", nodeSignals)
                parent.recycle()
                return true
            }
            currentParent = parent.parent
            parent.recycle()
            depth += 1
        }

        logRootMatchIfDebug(event, "copy_text_without_actionable_parent", nodeSignals)
        return false
    }

    private fun isActionableNode(node: AccessibilityNodeInfo): Boolean {
        return node.isClickable ||
            node.isLongClickable ||
            node.isFocusable ||
            node.actionList.any { action ->
                action.id == AccessibilityNodeInfo.ACTION_CLICK ||
                    action.id == AccessibilityNodeInfo.ACTION_LONG_CLICK
            }
    }

    private fun recycleQueue(queue: ArrayDeque<AccessibilityNodeInfo>) {
        while (queue.isNotEmpty()) {
            queue.removeFirst().recycle()
        }
    }

    private fun scheduleWindowProbe(event: AccessibilityEvent) {
        val eventType = event.eventType
        val windowChanges = event.windowChanges
        if (
            eventType != AccessibilityEvent.TYPE_WINDOWS_CHANGED ||
            windowChanges and AccessibilityEvent.WINDOWS_CHANGE_CHILDREN == 0
        ) {
            return
        }

        val token = windowProbeToken.incrementAndGet()
        val seenWallClockAtMs = System.currentTimeMillis()
        pendingWindowProbe?.let(mainHandler::removeCallbacks)
        pendingWindowProbe = Runnable {
            if (windowProbeToken.get() != token) return@Runnable
            if (BuildConfig.DEBUG) {
                Log.d(
                    TAG,
                    "Aggressive delayed probe: type=${eventTypeName(eventType)} " +
                        "windowChanges=$windowChanges"
                )
            }
            triggerCopyDetected(
                "${eventTypeName(eventType)} delayed_probe",
                ClipRelayService.CLIPBOARD_TRIGGER_TOOLBAR_CLOSE,
                minClipboardTimestampMs = seenWallClockAtMs
            )
        }
        mainHandler.postDelayed(pendingWindowProbe!!, WINDOW_PROBE_DELAY_MS)
    }

    private fun cancelWindowProbe() {
        windowProbeToken.incrementAndGet()
        pendingWindowProbe?.let(mainHandler::removeCallbacks)
        pendingWindowProbe = null
    }

    private fun logPotentialMissIfDebug(reason: String, event: AccessibilityEvent) {
        if (!BuildConfig.DEBUG) return

        val candidates = eventDebugCandidates(event)
        if (candidates.isEmpty()) return

        Log.d(
            TAG,
            "Potential copy miss: reason=$reason type=${eventTypeName(event.eventType)} " +
                "pkg=${event.packageName?.toString() ?: "unknown"} candidates=$candidates"
        )
    }

    private fun eventTypeName(eventType: Int): String {
        return when (eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED -> "view_clicked"
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> "window_state_changed"
            AccessibilityEvent.TYPE_WINDOWS_CHANGED -> "windows_changed"
            else -> eventType.toString()
        }
    }

    private fun eventDebugCandidates(event: AccessibilityEvent): List<String> {
        val signals = mutableListOf<String>()
        signals += event.text.map { it.toString() }
        event.contentDescription?.toString()?.let(signals::add)

        val source = event.source
        if (source != null) {
            try {
                signals += nodeSignals(source).toList()
            } finally {
                source.recycle()
            }
        }

        return heuristics.debugCopyCandidates(signals.asSequence())
    }

    private fun logWindowSignalsIfDebug(
        source: String,
        event: AccessibilityEvent,
        signals: List<String>
    ) {
        if (!BuildConfig.DEBUG) return
        val candidates = heuristics.debugCopyCandidates(signals.asSequence())
        if (candidates.isEmpty()) return
        Log.d(
            TAG,
            "Window copy candidates: source=$source type=${eventTypeName(event.eventType)} " +
                "windowChanges=${event.windowChanges} candidates=$candidates"
        )
    }

    private fun logRootMatchIfDebug(
        event: AccessibilityEvent,
        reason: String,
        signals: List<String>
    ) {
        if (!BuildConfig.DEBUG) return
        val candidates = heuristics.debugCopyCandidates(signals.asSequence())
        if (candidates.isEmpty()) return
        Log.d(
            TAG,
            "Root copy match: reason=$reason type=${eventTypeName(event.eventType)} " +
                "windowChanges=${event.windowChanges} candidates=$candidates"
        )
    }

    companion object {
        private const val TAG = "ClipboardA11y"
        private const val MAX_WINDOW_SCAN_NODES = 64
        private const val MAX_ACTIONABLE_ANCESTOR_DEPTH = 2
        private const val WINDOW_PROBE_DELAY_MS = 900L
    }

    private fun triggerCopyDetected(
        reason: String,
        triggerSource: String,
        minClipboardTimestampMs: Long? = null
    ) {
        heuristics.resetAfterDirectDetection()
        Log.d(TAG, "Copy detected via $reason")
        val intent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_ACCESSIBILITY_COPY_DETECTED
            putExtra(ClipRelayService.EXTRA_CLIPBOARD_TRIGGER_SOURCE, triggerSource)
            minClipboardTimestampMs?.let {
                putExtra(ClipRelayService.EXTRA_MIN_CLIPBOARD_TIMESTAMP_MS, it)
            }
        }
        ContextCompat.startForegroundService(this, intent)
    }

    override fun onInterrupt() {
        cancelWindowProbe()
        Log.d(TAG, "Accessibility service interrupted")
    }

    override fun onDestroy() {
        cancelWindowProbe()
        super.onDestroy()
    }
}
