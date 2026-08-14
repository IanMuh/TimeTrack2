import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import 'app.dart';
import 'data/database/app_database.dart';
import 'stores/app_store.dart';

/// 依赖注入容器（阶段 3d：AppStore 组装注册；阶段 4 UI 从中取 store）。
final GetIt getIt = GetIt.instance;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 组装数据层 + 全部 store（打开平台数据库、seed、启动编排）。
  final appStore = await AppStore.create(database: AppDatabase.open());
  getIt.registerSingleton<AppStore>(appStore);
  runApp(const TimeTrack2App());
}
