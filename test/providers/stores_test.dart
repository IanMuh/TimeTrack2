/// PR4-a：领域 store 装配归属（容器持有、TestStore 只接收实例）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/providers/stores.dart';

import '../support/provider_harness.dart';

void main() {
  // TestStore 装配会创建 TrayService（MethodChannel），需初始化绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('领域 store 由容器持有：TestStore 与 provider 是同一实例', () async {
    final container = createTestContainer();
    final domain = container.read(domainStoresProvider);
    final store = await pumpAppStore(container);

    expect(identical(store.timer, domain.timer), isTrue);
    expect(identical(store.category, domain.category), isTrue);
    expect(identical(store.activity, domain.activity), isTrue);
    expect(identical(store.settings, domain.settings), isTrue);
    // 释放责任已移交容器：TestStore.dispose 不再碰这四个 store。
    expect(store.ownsDomain, isFalse);
    expect(store.ownsFoundation, isFalse);
  });

  test('容器释放后领域 store 释放链路不抛（无二次 dispose）', () async {
    final container = createTestContainer();
    final domain = container.read(domainStoresProvider);
    await pumpAppStore(container);

    container.dispose();

    // 四个领域 store 均已去 ChangeNotifier（PR4-b），释放后仍可读普通字段；
    // 此处验证 provider onDispose → store.dispose 链路走通且不触发二次断言。
    expect(domain.timer.runningEntry, isNull);
  });
}

