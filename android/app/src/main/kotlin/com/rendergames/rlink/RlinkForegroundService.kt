package com.rendergames.rlink

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.Build
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Повышает приоритет процесса в фоне (BLE + relay + локальные уведомления),
 * пока пользователь не в основном окне приложения.
 */
class RlinkForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                // If this instance was started with startForegroundService, Android
                // requires startForeground() to be called before stopSelf().
                startAsFg()
                stopAsFg()
                markState(running = false)
                return START_NOT_STICKY
            }
            ACTION_START, null -> startAsFg()
            else -> startAsFg()
        }
        markState(running = true)
        // Keep process alive in background: Android may recreate the service after kill.
        return START_STICKY
    }

    override fun onDestroy() {
        markState(running = false)
        super.onDestroy()
    }

    /** Persisted (not just in-process) so it survives a process restart — the
     * delivery-diagnostics screen and the watchdog worker both read this.
     * [KEY_LAST_STARTED_AT] is never cleared on stop — it answers "when did we
     * last actually confirm this was alive", useful even while stopped. */
    private fun markState(running: Boolean) {
        try {
            val edit = getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit()
                .putBoolean(KEY_RUNNING, running)
            if (running) edit.putLong(KEY_LAST_STARTED_AT, System.currentTimeMillis())
            edit.apply()
        } catch (_: Exception) { }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java) ?: return
        val ch = NotificationChannel(
            CHANNEL_ID,
            "Rlink в фоне",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Приём сообщений, пока приложение свёрнуто"
            setShowBadge(false)
        }
        mgr.createNotificationChannel(ch)
    }

    private fun startAsFg() {
        ensureChannel()
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Rlink")
            .setContentText("Приём сообщений в фоне")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, types)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            try {
                startForeground(NOTIFICATION_ID, notification)
            } catch (_: Exception) { }
        }
    }

    private fun stopAsFg() {
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) { }
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        // If user swipes app from recents, request service restart shortly after.
        // This keeps relay/BLE listeners alive without touching backend.
        Handler(Looper.getMainLooper()).postDelayed({
            try {
                val restartIntent = Intent(applicationContext, RlinkForegroundService::class.java)
                    .setAction(ACTION_START)
                ContextCompat.startForegroundService(applicationContext, restartIntent)
            } catch (_: Exception) { }
        }, 1200)
    }

    companion object {
        const val ACTION_START = "com.rendergames.rlink.fg.START"
        const val ACTION_STOP = "com.rendergames.rlink.fg.STOP"
        private const val CHANNEL_ID = "rlink_foreground"
        private const val NOTIFICATION_ID = 71042
        const val PREFS_NAME = "rlink_delivery_health"
        const val KEY_RUNNING = "fg_running"
        const val KEY_LAST_STARTED_AT = "fg_last_started_at"
    }
}
