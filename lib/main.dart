import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'providers/bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Riverpod 容器是状态层的唯一实例源。启动期先 await 装配/编排完成再
  // runApp，保持“数据库不可用 → 错误页”的既有启动语义（启动期不引入加载屏，
  // 避免启动顺序与错误兜底行为发生变化）。
  final container = ProviderContainer();
  try {
    await container.read(startupProvider.future);
    // 路由/壳层经 TimeTrack2App 的 container 参数接入同一容器
    // （UncontrolledProviderScope 由根组件内部安装）。
    runApp(TimeTrack2App(container: container));
  } catch (e, st) {
    // 启动失败兜底（模块门禁 medium）：数据库损坏/迁移异常不得静默空白窗口
    // ——输出可诊断日志（含堆栈）后渲染错误页。
    // debug 下对非预期 Error（编程缺陷）rethrow 暴露真实 bug；预期的
    // 数据库异常（损坏/迁移）走错误页兜底。
    debugPrint('应用启动失败：$e\n$st');
    // 失败时释放容器：关闭数据库连接、释放装配过程中已创建的引擎。
    container.dispose();
    if (kDebugMode && e is Error) rethrow;
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
