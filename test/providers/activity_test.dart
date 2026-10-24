/// PR4-b 第一步：活动写路径的通知从 `ChangeNotifier` 迁移到 `activityProvider`。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/providers/stores.dart';
import 'package:timetrack2/utils/result.dart';
import 'package:timetrack2/viewmodels/activity.dart';
import 'package:timetrack2/viewmodels/commands/command_invocation.dart';

import '../support/provider_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('activityProvider 跟随 activity_create 指令与直接写路径递增', () async {
    final container = createTestContainer();
    final store = await pumpAppStore(container);
    final revisionBefore = store.dataRevision.value;

    expect(container.read(activityProvider), 0);

    final result = await store.dispatcher.dispatch(
      CommandInvocation(name: 'activity_create', args: ['阅读']),
    );
    expect(result, isA<CommandSuccess>());
    expect(container.read(activityProvider), 1);
    expect(store.dataRevision.value, revisionBefore + 1);

    final created = await container
        .read(activityProvider.notifier)
        .createActivity(name: '运动', color: 0xFF00FF00);
    expect(created, isA<AppSuccess<Activity>>());
    expect(container.read(activityProvider), 2);
  });

  test('撤销恢复也推进 activityProvider（applier onApplied 回调）', () async {
    final container = createTestContainer();
    final store = await pumpAppStore(container);
    // 先触发 build，让 onChanged 挂上（之后写入才能被捕捉）。
    expect(container.read(activityProvider), 0);

    await store.dispatcher.dispatch(
      CommandInvocation(name: 'activity_create', args: ['阅读']),
    );
    expect(container.read(activityProvider), 1);

    final undone = await store.undo.undo();
    expect(undone.isSuccess, isTrue);
    expect(container.read(activityProvider), 2);
  });
}
