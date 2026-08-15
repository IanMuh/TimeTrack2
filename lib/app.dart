import 'package:flutter/material.dart';

/// 阶段 0 空壳应用：仅验证工具链与地基可运行。
/// 主题令牌 / 路由 / 依赖注入在阶段 1 起按计划接入。
class TimeTrack2App extends StatelessWidget {
  const TimeTrack2App({super.key});

  /// 主题仅构造一次（r 修复）：`ColorScheme.fromSeed` 在 build() 中每次重建
  /// 都会重新计算——根组件被上层重建（DI/路由框架接入后）会重复昂贵的主题
  /// 构造；static final 只建一次且便于测试复用。
  static final ThemeData _theme = ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    useMaterial3: true,
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TimeTrack2',
      theme: _theme,
      home: const _ShellPage(),
    );
  }
}

class _ShellPage extends StatelessWidget {
  const _ShellPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TimeTrack2'),
      ),
      body: const Center(
        child: Text('阶段 0 骨架可运行'),
      ),
    );
  }
}
