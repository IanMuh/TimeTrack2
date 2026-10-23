/// PR4-b 第三步：分类写路径的通知从 `ChangeNotifier` 迁移到
/// `categoryChangeProvider`。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/providers/engines.dart';
import 'package:timetrack2/viewmodels/commands/command_invocation.dart';

import '../support/provider_harness.dart';

/// CategoryStore 经 `dataRevision` 监听异步 reload（库查询）后才通知，
/// 轮询等待，避免固定 sleep。
Future<int> _waitChange(
  ProviderContainer container,
  int expected, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  var value = container.read(categoryChangeProvider);
  while (value != expected && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    value = container.read(categoryChangeProvider);
  }
  return value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('categoryChangeProvider 跟随 category_create 递增', () async {
    final container = createTestContainer();
    final store = await pumpAppStore(container);

    expect(container.read(categoryChangeProvider), 0);

    final result = await store.dispatcher.dispatch(
      CommandInvocation(name: 'category_create', args: ['测试分类']),
    );
    expect(result, isA<CommandSuccess>());
    expect(await _waitChange(container, 1), 1);
  });

  test('撤销分类写路径也推进 categoryChangeProvider', () async {
    final container = createTestContainer();
    final store = await pumpAppStore(container);
    expect(container.read(categoryChangeProvider), 0);

    await store.dispatcher.dispatch(
      CommandInvocation(name: 'category_create', args: ['测试分类']),
    );
    expect(await _waitChange(container, 1), 1);

    final undone = await store.undo.undo();
    expect(undone.isSuccess, isTrue);
    expect(await _waitChange(container, 2), 2);
  });
}

