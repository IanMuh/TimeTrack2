package com.github.ianmuh.timetrack2

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/// 后台自动记录前台服务（批次 6b，契约 §6.4）：低优先级常驻通知——
/// 标题「正在记录」（暂停时「自动记录已暂停」），内容为命中活动名
/// （无命中「检测中…」）；点击回主界面；动作按钮暂停/恢复（语义 =
/// TrackingStore.sessionPaused 会话级挂起，经静态钩子回传 Dart）。
///
/// 生命周期：总开关开且已授权时由 Dart 经通道 startForegroundService 启动；
/// 关闭总开关/失权时 stopService。START_STICKY 保证系统回收后尽量自愈。
class TrackingForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        MainActivity.lastServiceInstance = this
    }

    override fun onDestroy() {
        if (MainActivity.lastServiceInstance === this) {
            MainActivity.lastServiceInstance = null
        }
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TOGGLE_PAUSE -> {
                // 状态真身在 Dart：仅回调钩子请求翻转；新文案随后经
                // updateNotification 推回。
                MainActivity.onPauseToggleRequested?.invoke()
                return START_STICKY
            }
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }
        val content = intent?.getStringExtra(EXTRA_CONTENT).orEmpty()
        val paused = intent?.getBooleanExtra(EXTRA_PAUSED, false) ?: false
        startForeground(NOTIFICATION_ID, buildNotification(content, paused))
        return START_STICKY
    }

    /// 更新通知内容/暂停态（不重复 startForeground）。
    fun update(contentText: String, paused: Boolean) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIFICATION_ID, buildNotification(contentText, paused))
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(contentText: String, paused: Boolean): Notification {
        val title = if (paused) "自动记录已暂停" else "正在记录"
        val text = contentText.ifEmpty { "检测中…" }

        val openIntent = packageManager
            .getLaunchIntentForPackage(packageName)
            ?.apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                )
            }
        val openPending = PendingIntent.getActivity(
            this, 0, openIntent, pendingFlags(),
        )

        val toggleIntent = Intent(this, TrackingForegroundService::class.java)
            .setAction(ACTION_TOGGLE_PAUSE)
        val togglePending = PendingIntent.getService(
            this, 1, toggleIntent, pendingFlags(),
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(openPending)
            .addAction(0, if (paused) "恢复记录" else "暂停记录", togglePending)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            builder.setPriority(Notification.PRIORITY_LOW)
        }
        return builder.build()
    }

    private fun pendingFlags(): Int {
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return flags
    }

    companion object {
        const val CHANNEL_ID = "timetrack_tracking"
        const val CHANNEL_NAME = "后台记录"
        const val NOTIFICATION_ID = 7002
        const val ACTION_TOGGLE_PAUSE = "com.github.ianmuh.timetrack2.TOGGLE_PAUSE"
        const val ACTION_STOP = "com.github.ianmuh.timetrack2.STOP"
        const val EXTRA_CONTENT = "content"
        const val EXTRA_PAUSED = "paused"
    }
}
