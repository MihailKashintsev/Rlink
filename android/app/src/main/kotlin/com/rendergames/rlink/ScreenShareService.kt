package com.rendergames.rlink

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Держит процесс в foreground-режиме типа mediaProjection на время
 * демонстрации экрана: без него Android 10+ не даёт захватывать экран, а на
 * Android 14+ бросает SecurityException. Запускается из Dart ПОСЛЕ того, как
 * пользователь выдал разрешение на захват (Helper.requestCapturePermission),
 * и до getDisplayMedia.
 */
class ScreenShareService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            try {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } catch (_: Exception) { }
            stopSelf()
            return START_NOT_STICKY
        }
        startAsFg()
        return START_NOT_STICKY
    }

    private fun startAsFg() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(NotificationManager::class.java)
            mgr?.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Демонстрация экрана",
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Rlink")
            .setContentText("Идёт демонстрация экрана")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        const val ACTION_STOP = "com.rendergames.rlink.screenshare.STOP"
        private const val CHANNEL_ID = "rlink_screen_share"
        private const val NOTIFICATION_ID = 71043
    }
}
