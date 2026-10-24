/// 基础设施 provider（Riverpod 迁移 B0 地基）。
///
/// 依赖方向：constants ← providers ← pages/app。providers 层可依赖 data/api
/// 与 constants，不依赖 stores/pages。
///
/// B0 只抽出“启动装配的输入”，仓储与领域 provider 随 B2/B3 页面迁移按需
/// 增加——不预先铺开无人消费的 provider（避免死代码与不必要的失效链）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/supabase/sync_backend.dart';
import '../data/database/app_database.dart';
import '../data/update/windows_installer.dart';

/// 应用数据库（单例；容器释放时关闭连接）。
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase.open();
  ref.onDispose(database.close);
  return database;
});

/// 应用版本号（关于/更新卡展示；阶段 4 由 pubspec 注入，二期可换
/// package_info_plus）。
final appVersionProvider = Provider<String>((ref) => '0.1.0');

/// 云同步后端。未配置 Supabase 时保持 Noop（完全离线）。
///
/// 真实后端接线属于阶段 5 云同步收口；此处先保留注入点、启动编排接线时
/// 按配置切换。
final syncBackendProvider = Provider<SyncBackend>((ref) => NoopSyncBackend());

/// 时钟注入点（测试固定时间；null = 系统时钟）。
final nowProvider = Provider<DateTime Function()?>((ref) => null);

/// Windows 安装器注入点（null = WindowsInstaller 的平台默认装配）。
final windowsInstallerProvider = Provider<WindowsInstaller?>((ref) => null);

/// 更新清单 URL 注入点（null = UpdateConfig.defaultManifestUrl）。
final updateManifestUrlProvider = Provider<Uri?>((ref) => null);

/// 启动时是否执行网络/清理编排（测试关；生产开）。
final runStartupChecksProvider = Provider<bool>((ref) => true);
