import 'package:flutter/material.dart';

/// 阶段 0 空壳应用：仅验证工具链与地基可运行。
/// 主题令牌 / 路由 / 依赖注入在阶段 1 起按计划接入。
class TimeTrack2App extends StatelessWidget {
  const TimeTrack2App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TimeTrack2',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
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
