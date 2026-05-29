package app.raven.feature.e2ee

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import java.util.concurrent.TimeUnit
import javax.inject.Singleton

/**
 * Phase 2f signed-prekey rotation worker.
 *
 * Every [ROTATION_INTERVAL_HOURS] hours WorkManager fires this worker,
 * which flips [PrekeyBundleService]'s "needs-republish" flag and then
 * calls [PrekeyBundleService.ensurePublished] — which mints a fresh
 * SPK + signs it + uploads to the server. Old SPK private bytes are
 * overwritten in `SecureStore`, which has two consequences:
 *
 *   • A peer who fetched our bundle BEFORE the rotation already
 *     X3DH'd with the old SPK and cached a SessionState. Their
 *     existing session keeps working because the root key is
 *     cached on both sides — they never need our SPK priv again
 *   • A peer fetching our bundle AFTER the rotation gets the new
 *     SPK and establishes a fresh session keyed on it
 *
 * Trade-off: a stolen-device attacker who captures the SPK priv
 * NOW has a ROTATION_INTERVAL-hour window to decrypt inbound
 * sessions established with that key. Shorter intervals tighten
 * the window; longer intervals reduce server publish load. 24h is
 * the Signal-spec default and matches iOS.
 *
 * Hilt integration:
 *   We deliberately AVOID @HiltWorker + Configuration.Provider here.
 *   That route requires an Application-level WorkerFactory + manifest
 *   override of the default WorkManagerInitializer, both of which are
 *   easy to misconfigure (silent "no worker factory" runtime errors).
 *   Instead, we pull the dependency through Hilt's [EntryPointAccessors]
 *   at run time — slightly heavier per invocation, but the worker
 *   only runs once a day, so it's the simpler-correct trade.
 */
class PrekeyRotationWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    @EntryPoint
    @InstallIn(SingletonComponent::class)
    interface WorkerDeps {
        fun prekeyBundleService(): PrekeyBundleService
    }

    override suspend fun doWork(): Result {
        return try {
            val deps = EntryPointAccessors.fromApplication<WorkerDeps>(applicationContext)
            val service = deps.prekeyBundleService()
            service.markNeedsRepublish()
            service.ensurePublished()
            Log.i(LOG_TAG, "Periodic SPK rotation complete")
            Result.success()
        } catch (t: Throwable) {
            // Retry per WorkManager backoff — typically network blip.
            // PrekeyBundleService.ensurePublished is already idempotent
            // so re-firing tomorrow if today errored is fine.
            Log.w(LOG_TAG, "SPK rotation failed: ${t.message}")
            Result.retry()
        }
    }

    companion object {
        private const val LOG_TAG = "PrekeyRotation"

        /** Phase 2f: 24 hours, matching iOS + Signal-spec default. */
        const val ROTATION_INTERVAL_HOURS = 24L

        const val UNIQUE_WORK_NAME = "raven.e2ee.prekey-rotation"
    }
}

/**
 * Schedule the periodic [PrekeyRotationWorker]. Idempotent — if the
 * work is already enqueued (KEEP policy), the second call is a no-op.
 *
 * Wire this from the auth-state observer (call on SIGNED_IN), so a
 * sign-out tears down and a fresh sign-in re-schedules.
 */
@Singleton
class PrekeyRotationScheduler @javax.inject.Inject constructor(
    @dagger.hilt.android.qualifiers.ApplicationContext
    private val context: Context,
) {

    fun schedule() {
        val constraints = Constraints.Builder()
            // The worker only does a single POST + write to local
            // SecureStore; needs the network and that's it.
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        val request = PeriodicWorkRequestBuilder<PrekeyRotationWorker>(
            PrekeyRotationWorker.ROTATION_INTERVAL_HOURS,
            TimeUnit.HOURS,
        )
            .setConstraints(constraints)
            .build()

        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            PrekeyRotationWorker.UNIQUE_WORK_NAME,
            // KEEP — let the existing schedule continue if already
            // enqueued. We use REPLACE in [reschedule] when the user
            // signs back in with a different account so the worker
            // re-binds to the new user.
            ExistingPeriodicWorkPolicy.KEEP,
            request,
        )
    }

    fun cancel() {
        WorkManager.getInstance(context).cancelUniqueWork(
            PrekeyRotationWorker.UNIQUE_WORK_NAME,
        )
    }
}
