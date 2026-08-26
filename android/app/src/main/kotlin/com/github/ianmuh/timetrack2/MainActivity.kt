package com.github.ianmuh.timetrack2

import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// 批次 6b：Android 平台通道（timetrack/platform/android_tracking）。
///
/// 职责：
/// - 「使用情况访问」权限判定与跳转（该权限不能运行时弹窗，只能进系统
///   设置授予——契约 §6.2）；
/// - 通知权限运行时请求（API 33+，前台服务常驻通知可见性）；
/// - UsageStats 最近前台包名查询（后台自动检测的数据源）；
/// - 前台服务 start/stop/updateNotification；通知「暂停」动作经
///   [onPauseToggleRequested] 钩子回传 Dart（状态真身在 TrackingStore）。
class MainActivity : FlutterActivity() {
    private val channelName = "timetrack/platform/android_tracking"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val trackingChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        )
        trackingChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isUsageGranted" -> result.success(isUsageAccessGranted())
                    "latestForegroundPackage" -> result.success(latestForegroundPackage())
                    "openUsageAccessSettings" -> {
                        startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                        result.success(true)
                    }
                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            requestPermissions(
                                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                                REQUEST_POST_NOTIFICATIONS,
                            )
                        }
                        result.success(true)
                    }
                    "startTrackingService" -> {
                        val paused = call.argument<Boolean>("paused") ?: false
                        val content = call.argument<String>("content").orEmpty()
                        val intent = Intent(this, TrackingForegroundService::class.java)
                            .putExtra(TrackingForegroundService.EXTRA_PAUSED, paused)
                            .putExtra(TrackingForegroundService.EXTRA_CONTENT, content)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }
                    "stopTrackingService" -> {
                        stopService(
                            Intent(this, TrackingForegroundService::class.java),
                        )
                        result.success(true)
                    }
                    "updateNotification" -> {
                        val paused = call.argument<Boolean>("paused") ?: false
                        val content = call.argument<String>("content").orEmpty()
                        // 服务可能尚未运行（未授权总开关等）：找不到则静默忽略。
                        val service = lastServiceInstance
                        service?.update(content, paused) ?: run {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // 通知「暂停/恢复」动作 → Dart 翻转 sessionPaused（经桥的入站事件）。
        onPauseToggleRequested = {
            trackingChannel.invokeMethod("onPauseToggleRequested", null)
        }
    }

    override fun onDestroy() {
        onPauseToggleRequested = null
        lastServiceInstance = null
        super.onDestroy()
    }

    /// 「使用情况访问」是否已授予（AppOps 判定，与系统设置页口径一致）。
    private fun isUsageAccessGranted(): Boolean {
        val ops = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ops.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                packageName,
            )
        } else {
            @Suppress("DEPRECATION")
            ops.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                packageName,
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    /// 最近一次进入前台的 应用包名（UsageEvents 取窗口内最后一条
    /// ACTIVITY_RESUMED / MOVE_TO_FRONT）；未授权或无事件返回空串。
    private fun latestForegroundPackage(): String {
        if (!isUsageAccessGranted()) return ""
        return try {
            val manager =
                getSystemService(Context.USAGE_STATS_SERVICE) as android.app.usage.UsageStatsManager
            val now = System.currentTimeMillis()
            val events = manager.queryEvents(now - EVENT_WINDOW_MS, now)
            var lastPackage: String? = null
            val event = android.app.usage.UsageEvents.Event()
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                // 原始事件值跨版本稳定：1=ACTIVITY_RESUMED(29+)，2=MOVE_TO_FRONT(旧版)。
                if (event.eventType == EVENT_TYPE_ACTIVITY_RESUMED ||
                    event.eventType == EVENT_TYPE_MOVE_TO_FRONT
                ) {
                    lastPackage = event.packageName
                }
            }
            lastPackage ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    companion object {
        private const val REQUEST_POST_NOTIFICATIONS = 7001

        /// 事件回看窗口（毫秒）：覆盖轮询间隔内的最近一次前台切换即可。
        private const val EVENT_WINDOW_MS = 60_000L

        // UsageEvents.Event 事件类型原始值（新 SDK 已移除常量名，值不变）。
        private const val EVENT_TYPE_ACTIVITY_RESUMED = 1
        private const val EVENT_TYPE_MOVE_TO_FRONT = 2

        /// 通知「暂停/恢复」动作 → Dart 翻转 sessionPaused（MainActivity
        /// 与服务同进程同主线程，静态钩子最简可靠）。
        @JvmStatic
        var onPauseToggleRequested: (() -> Unit)? = null

        /// 当前运行中的服务实例引用（updateNotification 直达，免再发 intent）。
        @JvmStatic
        var lastServiceInstance: TrackingForegroundService? = null
    }
}
