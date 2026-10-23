import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/providers/data.dart';
import 'package:timetrack2/providers/engines.dart';
import 'package:timetrack2/stores/update_store.dart' show UpdateState;

import '../support/provider_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('B4a 引擎快照 provider', () {
    test('timerSnapshotProvider 随运行条目变化（值快照，不用对象身份）', () async {
      final container = createTestContainer();
      addTearDown(container.dispose);
      final store = await pumpAppStore(container);

      final activities = await container.read(activitiesProvider.future);
      final unassignedId =
          await container.read(unassignedActivityIdProvider.future);
      final target = activities.firstWhere((a) => a.id != unassignedId);

      final states = <TimerSnapshot>[];
      container.listen(
        timerSnapshotProvider,
        (_, next) => states.add(next),
        fireImmediately: true,
      );
      expect(states.single.isRunning, isFalse);

      final switched = await store.timer.switchToActivity(target.id);
      expect(switched.isSuccess, isTrue);
      expect(states.last.entryId, isNotNull);
      expect(states.last.activityId, target.id);
      expect(states.last.startAt, isNotNull);

      // 上游重复 notify（缓存刷新，运行条目本身不变）不应产生新快照。
      final before = states.length;
      await store.timer.refresh();
      expect(states.length, before);

      final entryIdWhileRunning = states.last.entryId;

      await store.timer.stopRunning();
      // stop 的产品语义 = 切到「未分配」活动（仍存在运行条目），
      // 快照应体现 activityId 变化、而不是 entryId 归空。
      expect(states.last.isRunning, isTrue);
      expect(states.last.activityId, unassignedId);
      expect(states.last.entryId, isNot(entryIdWhileRunning));
    });

    test('reminder/update 快照初值为“无提醒 / idle”', () async {
      final container = createTestContainer();
      addTearDown(container.dispose);
      final store = await pumpAppStore(container);

      expect(container.read(reminderSnapshotProvider).hasReminder, isFalse);
      final update = container.read(updateSnapshotProvider);
      expect(update.state, UpdateState.idle);
      expect(update, UpdateSnapshot.from(store.update));
    });
  });
}

