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
/// - 前台服务 start/stop；通知「暂停」动作经 [onPauseToggleRequested]
///   钩子回传 Dart（状态真身在 TrackingStore）。
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
                        // 用户可见文案（铁律 6）：Dart 侧 ARB 本地化后随
                        // intent 下发，原生不硬编码。
                        val title = call.argument<String>("title").orEmpty()
                        val content = call.argument<String>("content").orEmpty()
                        val actionLabel = call.argument<String>("actionLabel").orEmpty()
                        val channelName = call.argument<String>("channelName").orEmpty()
                        val intent = Intent(this, TrackingForegroundService::class.java)
                            .putExtra(TrackingForegroundService.EXTRA_PAUSED, paused)
                            .putExtra(TrackingForegroundService.EXTRA_TITLE, title)
                            .putExtra(TrackingForegroundService.EXTRA_CONTENT, content)
                            .putExtra(TrackingForegroundService.EXTRA_ACTION_LABEL, actionLabel)
                            .putExtra(TrackingForegroundService.EXTRA_CHANNEL_NAME, channelName)
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

    /// 最近一次进入前台的 **非本应用** 包名（UsageEvents 取窗口内最后一条
    /// ACTIVITY_RESUMED）；未授权或无事件返回空串。
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
                // 只匹配 ACTIVITY_RESUMED（值 1，跨版本稳定）。旧值 2 是
                // MOVE_TO_BACKGROUND/PAUSED（退后台）——旧注释误作"到前台"，
                // 匹配它会把刚切走的应用当成"最后前台包"。
                // 排除本应用：调用方（「捕获当前前台」）此刻必然在本应用
                // 前台——不过滤的话捕获结果恒为本包名，建出的规则只匹配
                // TimeTrack2 自己。
                if (event.eventType != EVENT_TYPE_ACTIVITY_RESUMED) continue
                if (event.packageName == packageName) continue
                lastPackage = event.packageName
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

        /// 通知「暂停/恢复」动作 → Dart 翻转 sessionPaused（MainActivity
        /// 与服务同进程同主线程，静态钩子最简可靠）。
        @JvmStatic
        var onPauseToggleRequested: (() -> Unit)? = null
    }
}
