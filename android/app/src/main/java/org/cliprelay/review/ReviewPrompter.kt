package org.cliprelay.review

// Gently nudges happy users toward a Play Store review via the in-app review API.
// Gate: enough successful syncs + install age, at most once per re-prompt interval.
// The prompt fires right after a successful sync while the app is foregrounded, so
// the user has just watched the app work.

import android.app.Activity
import android.content.Context
import com.google.android.play.core.review.ReviewManagerFactory
import java.util.concurrent.TimeUnit

/** Pure gate logic, separated for unit testing. */
object ReviewPromptGate {
    const val MIN_SYNCS = 10
    val MIN_INSTALL_AGE_MS: Long = TimeUnit.DAYS.toMillis(1)
    val REPROMPT_INTERVAL_MS: Long = TimeUnit.DAYS.toMillis(60)

    fun shouldPrompt(
        nowMs: Long,
        installTimeMs: Long,
        syncCount: Int,
        lastPromptMs: Long
    ): Boolean =
        syncCount >= MIN_SYNCS &&
            nowMs - installTimeMs >= MIN_INSTALL_AGE_MS &&
            (lastPromptMs == 0L || nowMs - lastPromptMs >= REPROMPT_INTERVAL_MS)
}

/** Persists the sync counter and last-prompt timestamp in SharedPreferences. */
class ReviewPromptStore(private val context: Context) {
    private val prefs = context.getSharedPreferences("review_prompt", Context.MODE_PRIVATE)
    // Lazy: the service instance only ever records syncs and must not pay the
    // PackageManager binder call on its session thread.
    private val installTimeMs by lazy {
        context.packageManager.getPackageInfo(context.packageName, 0).firstInstallTime
    }

    /**
     * Called on every successful clipboard sync, either direction. Runs on the BLE
     * session thread, so it stops writing once the gate threshold is reached — after
     * that the exact count no longer matters. (The read-modify-write is not atomic
     * across session threads; a lost increment below the threshold only delays the
     * prompt by one sync, so no locking.)
     */
    fun recordSync() {
        val count = prefs.getInt(KEY_SYNC_COUNT, 0)
        if (count >= ReviewPromptGate.MIN_SYNCS) return
        prefs.edit().putInt(KEY_SYNC_COUNT, count + 1).apply()
    }

    fun shouldPrompt(nowMs: Long = System.currentTimeMillis()): Boolean =
        ReviewPromptGate.shouldPrompt(
            nowMs = nowMs,
            installTimeMs = installTimeMs,
            syncCount = prefs.getInt(KEY_SYNC_COUNT, 0),
            lastPromptMs = prefs.getLong(KEY_LAST_PROMPT, 0L)
        )

    fun markPrompted(nowMs: Long = System.currentTimeMillis()) {
        prefs.edit().putLong(KEY_LAST_PROMPT, nowMs).apply()
    }

    /**
     * Launch the Play in-app review flow if the gate allows it. Marks the attempt
     * up front: Play may silently decline to show the dialog (quota), and either
     * way we must not re-request on every subsequent sync.
     */
    fun maybeLaunchReviewFlow(activity: Activity) {
        if (!shouldPrompt()) return
        markPrompted()
        val manager = ReviewManagerFactory.create(activity)
        manager.requestReviewFlow().addOnSuccessListener { reviewInfo ->
            if (!activity.isFinishing && !activity.isDestroyed) {
                manager.launchReviewFlow(activity, reviewInfo)
            }
        }
        // ponytail: failures ignored on purpose — no Play Store on device etc.; next chance in 60 days.
    }

    private companion object {
        const val KEY_SYNC_COUNT = "sync_count"
        const val KEY_LAST_PROMPT = "last_prompt_time"
    }
}
