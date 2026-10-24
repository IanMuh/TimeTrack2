/// PR4-b 第四步：计时写路径的通知从 `ChangeNotifier` 迁移到
/// `timerChangeProvider` / `timerSnapshotProvider` 的监听表。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/providers/data.dart';
import 'package:timetrack2/providers/engines.dart';
import 'package:timetrack2/viewmodels/commands/command_invocation.dart';

import '../support/provider_harness.dart';

Future<int> _wait(
  ProviderContainer container,
  NotifierProvider<TimerChangeNotifier, int> provider,
  int expected,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  var value = container.read(provider);
  while (value != expected && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    value = container.read(provider);
  }
  return value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('timerChangeProvider 与计时快照跟随 switch/stop', () async {
    final container = createTestContainer();
    final store = await pumpAppStore(container);
    expect(container.read(timerChangeProvider), 0);
    expect(container.read(timerSnapshotProvider).entryId, isNull);

    final activities = await container.read(activitiesProvider.future);
    final first = activities.first;

    final switched = await store.dispatcher.dispatch(
      CommandInvocation(name: 'switch', args: [first.name]),
    );
    expect(switched, isA<CommandSuccess>());
    expect(await _wait(container, timerChangeProvider, 1), 1);
    expect(container.read(timerSnapshotProvider).activityId, first.id);
    expect(container.read(timerSnapshotProvider).activityName, first.name);

    final stopped = await store.dispatcher.dispatch(
      CommandInvocation(name: 'stop'),
    );
    expect(stopped, isA<CommandSuccess>());
    expect(await _wait(container, timerChangeProvider, 2), 2);
    // 产品语义：stop = 切到未分配活动（仍有一个运行条目，不是 null）。
    expect(container.read(timerSnapshotProvider).entryId, isNotNull);
  });
}
