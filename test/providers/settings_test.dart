/// PR4-b 第二步：设置写路径的通知从 `ChangeNotifier` 迁移到
/// `settingsChangeProvider`。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/providers/engines.dart';
import 'package:timetrack2/viewmodels/profile_settings.dart';

import '../support/provider_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('settingsChangeProvider 跟随 save 递增，current 与库同步', () async {
    final container = createTestContainer();
    final store = await pumpAppStore(container);

    expect(container.read(settingsChangeProvider), 0);
    final before = store.settings.current!;

    final saved = await store.settings.save(
      before.copyWith(themeMode: ThemeModeSetting.dark),
    );
    expect(saved.isSuccess, isTrue);
    expect(container.read(settingsChangeProvider), 1);
    expect(
      container.read(settingsStoreProvider).current?.themeMode,
      ThemeModeSetting.dark,
    );
  });

  test('撤销恢复设置也推进 settingsChangeProvider', () async {
    final container = createTestContainer();
    final store = await pumpAppStore(container);
    expect(container.read(settingsChangeProvider), 0);
    final before = store.settings.current!;

    await store.settings.save(before.copyWith(use24HourFormat: false));
    expect(container.read(settingsChangeProvider), 1);

    final undone = await store.undo.undo();
    expect(undone.isSuccess, isTrue);
    expect(container.read(settingsChangeProvider), 2);
    expect(
      container.read(settingsStoreProvider).current?.use24HourFormat,
      before.use24HourFormat,
    );
  });
}

