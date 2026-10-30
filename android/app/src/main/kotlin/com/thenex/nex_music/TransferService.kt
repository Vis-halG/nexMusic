package com.thenex.nex_music

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

/** Keeps user-started Dart transfers running when the screen is locked. */
class TransferService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        NexPhone.createChannels(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (owners.isEmpty()) {
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = NotificationCompat.Builder(this, "transfers")
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(0xFF7C3AED.toInt())
            .setContentTitle("nexMusic transfers")
            .setContentText("Uploads and downloads continue with the screen locked")
            .setContentIntent(NexPhone.openAppIntent(this, "downloads", NOTIFICATION_ID))
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: IllegalStateException) {
            Log.w("nexMusic", "Android deferred background transfers", error)
            stopSelf()
            return START_NOT_STICKY
        }
        if (wakeLock?.isHeld != true) {
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "nexMusic:transfers")
                .apply {
                    setReferenceCounted(false)
                    // Android 15 also limits dataSync foreground work to six hours.
                    acquire(6 * 60 * 60 * 1000L)
                }
        }
        // Queues already persist on disk. Do not restart an empty Dart engine.
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Stop within Android 15's deadline; persisted queues resume on reopening.
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        private const val NOTIFICATION_ID = 1002
        private val owners = mutableSetOf<String>()

        fun setActive(context: Context, owner: String, active: Boolean) {
            if (active) owners.add(owner) else owners.remove(owner)
            refresh(context)
        }

        fun refresh(context: Context) {
            val intent = Intent(context, TransferService::class.java)
            if (owners.isEmpty()) {
                context.stopService(intent)
                return
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: IllegalStateException) {
                // Android may refuse a restored queue while backgrounded. The
                // activity retries on resume without losing its saved work.
                Log.w("nexMusic", "Transfer service will retry on resume", error)
            }
        }
    }
}
