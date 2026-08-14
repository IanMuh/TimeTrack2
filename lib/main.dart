import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import 'app.dart';
import 'data/database/app_database.dart';
import 'stores/app_store.dart';

/// 依赖注入容器（阶段 3d：AppStore 组装注册；阶段 4 UI 从中取 store）。
final GetIt getIt = GetIt.instance;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    // 组装数据层 + 全部 store（打开平台数据库、seed、启动编排）。
    final appStore = await AppStore.create(database: AppDatabase.open());
    getIt.registerSingleton<AppStore>(appStore);
    runApp(const TimeTrack2App());
  } catch (e) {
    // 启动失败兜底（模块门禁 medium）：数据库损坏/迁移异常不得静默空白
    // 窗口——输出可诊断日志后仍渲染错误页（数据不可用时引导用户）。
    debugPrint('应用启动失败：$e');
    runApp(const _StartupErrorApp());
  }
}

/// 启动失败占位页（数据层不可用时的可诊断提示；阶段 4 正式错误页）。
class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TimeTrack2',
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.error_outline, size: 48),
              SizedBox(height: 16),
              Text('应用启动失败，请检查数据文件后重试'),
            ],
          ),
        ),
      ),
    );
  }
}
