/// 应用装配 provider（Riverpod 迁移 B0 过渡层）。
///
/// B0 阶段 AppStore 仍是“装配 + 启动编排”的聚合对象，只是依赖改由 provider
/// 注入；B2-B4 逐个把 store 拆成独立 provider 后删除 AppStore。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../stores/app_store.dart';
import 'infrastructure.dart';

/// 应用聚合 store（异步装配：打开库 → seed → 各 store 首次加载 → 启动编排）。
///
/// - keepAlive（默认）：装配一次，页面/测试共享同一实例；
/// - [ref.onDispose]：容器释放时按 [AppStore.dispose] 的既定顺序释放 store
///   （ClockStore 的 1Hz 定时器、数据库连接等），避免迁移期出现“旧实现
///   从不 dispose”的泄漏；
/// - B0 的 main 仍 `await` 它完成后再 `runApp`，启动顺序与错误页行为不变。
final appStoreProvider = FutureProvider<AppStore>((ref) async {
  final store = await AppStore.create(
    database: ref.watch(appDatabaseProvider),
    backend: ref.watch(syncBackendProvider),
    now: ref.watch(nowProvider),
    windowsInstaller: ref.watch(windowsInstallerProvider),
    updateManifestUrl: ref.watch(updateManifestUrlProvider),
    currentVersion: ref.watch(appVersionProvider),
    runStartupChecks: ref.watch(runStartupChecksProvider),
  );
  ref.onDispose(store.dispose);
  return store;
});
