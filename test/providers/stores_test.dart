/// PR4-a：领域 store 装配归属（容器持有、AppStore 只接收实例）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/providers/stores.dart';

import '../support/provider_harness.dart';

void main() {
  // AppStore 装配会创建 TrayService（MethodChannel），需初始化绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('领域 store 由容器持有：AppStore 与 provider 是同一实例', () async {
    final container = createTestContainer();
    final domain = container.read(domainStoresProvider);
    final store = await pumpAppStore(container);

    expect(identical(store.timer, domain.timer), isTrue);
    expect(identical(store.category, domain.category), isTrue);
    expect(identical(store.activity, domain.activity), isTrue);
    expect(identical(store.settings, domain.settings), isTrue);
    // 释放责任已移交容器：AppStore.dispose 不再碰这四个 store。
    expect(store.ownsDomain, isFalse);
    expect(store.ownsFoundation, isFalse);
  });

  test('容器释放后领域 store 被释放（无二次 dispose 断言）', () async {
    final container = createTestContainer();
    final domain = container.read(domainStoresProvider);
    await pumpAppStore(container);

    container.dispose();

    // ChangeNotifier 在 dispose 后再被监听会抛 FlutterError；能抛说明释放
    // 路径由 provider 走通，且 AppStore 没有重复 dispose 触发断言。
    expect(() => domain.settings.addListener(() {}), throwsFlutterError);
    expect(() => domain.timer.addListener(() {}), throwsFlutterError);
    expect(() => domain.category.addListener(() {}), throwsFlutterError);
    // 活动已去 ChangeNotifier（PR4-b），无 dispose 可断言；其通知走
    // activityProvider，见 activity_test.dart。
  });
}
