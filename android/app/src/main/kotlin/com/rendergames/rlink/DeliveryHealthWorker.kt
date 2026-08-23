package com.rendergames.rlink

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * Periodic watchdog for [RlinkForegroundService]. Doze and OEM battery
 * managers (Xiaomi/Huawei/Oppo/Samsung...) can stop a foreground service
 * outright despite START_STICKY and onTaskRemoved's restart. WorkManager
 * (AndroidX, no Google Play Services dependency) survives those the same
 * killers target the service for, so it's a second, independent chance to
 * revive it. Unconditionally re-issuing ACTION_START is safe — the service's
 * onStartCommand is idempotent (just re-posts the same notification).
 */
class DeliveryHealthWorker(context: Context, params: WorkerParameters) :
    CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        try {
            val intent = Intent(applicationContext, RlinkForegroundService::class.java)
                .setAction(RlinkForegroundService.ACTION_START)
            ContextCompat.startForegroundService(applicationContext, intent)
        } catch (_: Exception) {
            return Result.retry()
        }
        return Result.success()
    }

    companion object {
        private const val UNIQUE_WORK_NAME = "rlink_delivery_health_watchdog"

        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<DeliveryHealthWorker>(
                15, TimeUnit.MINUTES, // WorkManager's floor for periodic work
            ).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                UNIQUE_WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request,
            )
        }
    }
}
