package com.vibepad

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.vibepad.capsule.CapsuleStore
import com.vibepad.trackpad.HidDeviceController
import com.vibepad.voice.CapsuleSyncClient
import com.vibepad.voice.PhoneVoiceController

/**
 * Keeps the HID registration and pointer pipeline alive while the app is in
 * the background. The Bluetooth stack drops the HID app when the process dies,
 * so this service is part of the connection contract, not just a notification.
 */
class VibePadService : Service() {

    private var capsuleSync: CapsuleSyncClient? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        HidDeviceController.init(this)
        PhoneVoiceController.init(this)
        CapsuleStore.init(this)
        capsuleSync = CapsuleSyncClient(this).also { it.start() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        HidDeviceController.init(this)
        PhoneVoiceController.init(this)
        return START_STICKY
    }

    override fun onDestroy() {
        capsuleSync?.shutdown()
        capsuleSync = null
        PhoneVoiceController.shutdown()
        HidDeviceController.shutdown()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "VibePad",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "触控板和语音连接状态"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pending = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_input_get)
            .setContentTitle("VibePad")
            .setContentText("触控板已就绪")
            .setContentIntent(pending)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "vibepad"
        private const val NOTIFICATION_ID = 1001

        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, VibePadService::class.java)
            )
        }
    }
}
