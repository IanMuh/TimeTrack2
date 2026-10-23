import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/providers/app.dart';
import 'package:timetrack2/providers/infrastructure.dart';

import '../support/provider_harness.dart';

void main() {
  // AppStore 装配 TrayService（批次 6）：MethodChannel 处理器注册需要 Binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('appStoreProvider（Riverpod B0 地基）', () {
    test('用容器注入的数据库装配，并完成 seed 与首次加载', () async {
      final container = createTestContainer();
      final store = await pumpAppStore(container);

      // 装配输入来自 provider（数据库同一实例）。
      expect(
        identical(store.database, container.read(appDatabaseProvider)),
        isTrue,
      );

      // seed 后默认活动可用；今日条目为空、加载无失败。
      final activities = (await store.activities.activities()).requireValue();
      expect(activities, isNotEmpty);
      expect(store.today.today, isEmpty);
      expect(store.today.loadFailed, isFalse);
    });

    test('keepAlive：重复读取返回同一 AppStore 实例', () async {
      final container = createTestContainer();

      final first = await pumpAppStore(container);
      final second = await container.read(appStoreProvider.future);

      expect(identical(first, second), isTrue);
    });

    test('容器释放时按 AppStore.dispose 释放 store（时钟已不可用）', () async {
      final container = createTestContainer();
      final store = await pumpAppStore(container);

      container.dispose();

      // ChangeNotifier.dispose 后 addListener 抛 FlutterError：证明
      // ref.onDispose → AppStore.dispose 链路生效（旧实现生产路径从不释放）。
      expect(() => store.clock.addListener(() {}), throwsA(isA<FlutterError>()));
    });
  });
}
