package com.github.ianmuh.timetrack2

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/// 后台自动记录前台服务（批次 6b，契约 §6.4）：低优先级常驻通知——标题
/// 「正在记录」（暂停时「自动记录已暂停」），内容为命中活动名（无命中
/// 「检测中…」）；点击回主界面；动作按钮暂停/恢复（语义 =
/// TrackingStore.sessionPaused 会话级挂起，经静态钩子回传 Dart）。
///
/// 用户可见文案（标题/内容/动作/渠道名）由 Dart 经 intent extras 下发
/// （铁律 6：ARB 本地化——原生硬编码中文会让英文 locale 用户看到中文），
/// extras 缺失时回退内置中文默认值（仅兼容旧调用方）。
///
/// 生命周期：总开关开且已授权时由 Dart 经通道 startForegroundService 启动；
/// 关闭总开关/失权时 stopService。START_STICKY 保证系统回收后尽量自愈。
class TrackingForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TOGGLE_PAUSE -> {
                // 状态真身在 Dart：仅回调钩子请求翻转；新文案随后经
                // startTrackingService（幂等重发 intent）推回。
                MainActivity.onPauseToggleRequested?.invoke()
                return START_STICKY
            }
        }
        val paused = intent?.getBooleanExtra(EXTRA_PAUSED, false) ?: false
        val title = intent?.getStringExtra(EXTRA_TITLE)
            ?.ifEmpty { null } ?: DEFAULT_TITLE
        val content = intent?.getStringExtra(EXTRA_CONTENT).orEmpty()
        val actionLabel = intent?.getStringExtra(EXTRA_ACTION_LABEL)
            ?.ifEmpty { null } ?: DEFAULT_ACTION_LABEL
        val channelName = intent?.getStringExtra(EXTRA_CHANNEL_NAME)
            ?.ifEmpty { null } ?: DEFAULT_CHANNEL_NAME
        createChannel(channelName)
        val notification = buildNotification(
            title = title,
            contentText = content,
            actionLabel = actionLabel,
        )
        // targetSdk 34+：manifest 声明了 foregroundServiceType 时必须以三参
        // 重载显式传类型，两参版本会抛 MissingForegroundServiceTypeException。
        // specialUse 类型 API 34 才被系统识别——以下版本用两参重载（类型在
        // 旧平台为声明性信息）。dataSync 在 Android 15+ 有 24 小时 6 小时
        // 累计上限，与"全天后台记录"冲突，故用 specialUse。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    private fun createChannel(channelName: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                channelName,
                NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(
        title: String,
        contentText: String,
        actionLabel: String,
    ): Notification {
        val text = contentText.ifEmpty { "…" }

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
            .addAction(0, actionLabel, togglePending)
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
        const val NOTIFICATION_ID = 7002
        const val ACTION_TOGGLE_PAUSE = "com.github.ianmuh.timetrack2.TOGGLE_PAUSE"
        const val EXTRA_PAUSED = "paused"
        const val EXTRA_TITLE = "title"
        const val EXTRA_CONTENT = "content"
        const val EXTRA_ACTION_LABEL = "actionLabel"
        const val EXTRA_CHANNEL_NAME = "channelName"

        // extras 缺失时的回退默认值（仅兼容旧调用方；正常路径文案全量下发）。
        const val DEFAULT_TITLE = "TimeTrack2"
        const val DEFAULT_ACTION_LABEL = "…"
        const val DEFAULT_CHANNEL_NAME = "TimeTrack2"
    }
}
