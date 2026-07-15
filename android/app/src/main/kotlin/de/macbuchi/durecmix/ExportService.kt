package de.macbuchi.durecmix

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

// Foreground service shown while a render runs: exports of multi-GB DUREC
// recordings take minutes on a phone, and without a foreground service
// Android kills the process shortly after the app leaves the screen. The
// render itself stays on the Rust thread inside the app process — this
// service only pins the process alive and mirrors progress into the
// notification shade.
class ExportService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START, ACTION_UPDATE -> {
                val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
                val name = intent.getStringExtra(EXTRA_NAME) ?: "mix"
                val notification = buildNotification(name, progress)
                if (Build.VERSION.SDK_INT >= 34) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
            }
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(name: String, progress: Int): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Export", NotificationManager.IMPORTANCE_LOW),
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Exporting $name")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setProgress(100, progress.coerceIn(0, 100), false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    companion object {
        const val ACTION_START = "de.macbuchi.durecmix.export.START"
        const val ACTION_UPDATE = "de.macbuchi.durecmix.export.UPDATE"
        const val ACTION_STOP = "de.macbuchi.durecmix.export.STOP"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_NAME = "name"
        private const val CHANNEL_ID = "export"
        private const val NOTIFICATION_ID = 1
    }
}
