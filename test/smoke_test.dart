import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:timetrack2/app.dart';

void main() {
  testWidgets('阶段 0 空壳冒烟：应用可构建并渲染', (tester) async {
    await tester.pumpWidget(const TimeTrack2App());

    // MaterialApp 就位，空壳页面渲染出标题
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('TimeTrack2'), findsOneWidget);
  });
}
