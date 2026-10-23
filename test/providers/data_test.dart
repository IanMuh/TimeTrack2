import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/providers/data.dart';
import 'package:timetrack2/providers/foundation.dart';
import 'package:timetrack2/utils/date_time_ext.dart';

import '../support/provider_harness.dart';

void main() {
  // AppStore 装配 TrayService（批次 6）：MethodChannel 处理器注册需要 Binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('数据查询 provider（Riverpod B2）', () {
    test('dayEntriesProvider：写库 + 修订号失效后取到新条目', () async {
      final container = createTestContainer();
      await pumpAppStore(container);
      final today = DateTime.now().startOfDay;

      expect(await container.read(dayEntriesProvider(today).future), isEmpty);

      final unassigned = await container.read(
        unassignedActivityIdProvider.future,
      );
      expect(unassigned, isNotNull);
      final repo = container.read(timeEntryRepositoryProvider);
      final result = await repo.switchToActivity(
        unassigned!,
        at: today.add(const Duration(hours: 9)),
      );
      expect(result.isSuccess, isTrue);

      // 写路径统一 bump 修订号 → 查询 provider 失效重查（页面无需手工重载）。
      container.read(dataRevisionProvider.notifier).bump();
      final entries = await container.read(dayEntriesProvider(today).future);
      expect(entries, hasLength(1));
      expect(entries.single.activityId, unassigned);
    });

    test('rangeEntriesProvider：跨日范围一次覆盖（时间线/统计明细）', () async {
      final container = createTestContainer();
      await pumpAppStore(container);
      final today = DateTime.now().startOfDay;
      final yesterday = DateTime(today.year, today.month, today.day - 1);

      final unassigned = await container.read(
        unassignedActivityIdProvider.future,
      );
      final activities = await container.read(activitiesProvider.future);
      final target = activities.firstWhere((a) => a.id != unassigned);
      final repo = container.read(timeEntryRepositoryProvider);
      for (final (start, end) in [
        (
          yesterday.add(const Duration(hours: 9)),
          yesterday.add(const Duration(hours: 10)),
        ),
        (
          today.add(const Duration(hours: 9)),
          today.add(const Duration(hours: 10)),
        ),
      ]) {
        final created = await repo.createManualEntry(
          activityId: target.id,
          startAt: start,
          endAt: end,
          note: '',
        );
        expect(created.isSuccess, isTrue);
      }

      // autoDispose family：keepAlive 一个监听避免查询之间被回收。
      final key = (yesterday, today.add(const Duration(days: 1)));
      final sub = container.listen(rangeEntriesProvider(key), (_, _) {});
      addTearDown(sub.close);
      final entries =
          await container.read(rangeEntriesProvider(key).future);
      expect(entries, hasLength(2));
    });

    test('activitiesProvider：seed 后活动非空，未分配活动为唯一', () async {
      final container = createTestContainer();
      await pumpAppStore(container);

      final unassigned = await container.read(
        unassignedActivityIdProvider.future,
      );
      expect(unassigned, isNotNull);
      final activities = await container.read(activitiesProvider.future);
      expect(activities, isNotEmpty);
      expect(activities.where((a) => a.id == unassigned), hasLength(1));
      expect(activities.where((a) => a.isUnassigned), hasLength(1));
    });
  });
}
