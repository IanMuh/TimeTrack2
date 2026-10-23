import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/providers/data.dart';
import 'package:timetrack2/providers/foundation.dart';
import 'package:timetrack2/utils/date_time_ext.dart';
import 'package:timetrack2/utils/result.dart';
import 'package:timetrack2/viewmodels/stats/stats_models.dart';

import '../support/provider_harness.dart';

void main() {
  // AppStore 装配 TrayService：MethodChannel 处理器注册需要 Binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('statsProvider（Riverpod B3）', () {
    test('聚合 + 排除自动开关极性：默认计入，关闭后自动条目剔除', () async {
      final container = createTestContainer();
      await pumpAppStore(container);
      final today = DateTime.now().startOfDay;
      final repo = container.read(timeEntryRepositoryProvider);
      final activities = await container.read(activitiesProvider.future);
      final xuexi = activities.firstWhere((a) => a.name == '学习');

      // 手动 09:00-10:00（学习，60 分钟）。
      final manual = await repo.createManualEntry(
        activityId: xuexi.id,
        startAt: today.add(const Duration(hours: 9)),
        endAt: today.add(const Duration(hours: 10)),
        note: '',
      );
      expect(manual.isSuccess, isTrue);

      // 自动 10:00-10:20（自动备份，20 分钟；isAuto 落库）。
      final auto = (await container
              .read(activityRepositoryProvider)
              .createActivity(name: '自动备份', color: 1))
          .requireValue();
      final autoEntry = await repo.createManualEntry(
        activityId: auto.id,
        startAt: today.add(const Duration(hours: 10)),
        endAt: today.add(const Duration(hours: 10, minutes: 20)),
        note: '',
        isAuto: true,
      );
      expect(autoEntry.isSuccess, isTrue);

      StatsQuery query({required bool includeAuto}) => StatsQuery(
            start: today,
            end: today.add(const Duration(days: 1)),
            dimension: StatsDimension.activity,
            includeAuto: includeAuto,
          );

      final included =
          await container.read(statsProvider(query(includeAuto: true)).future);
      expect(
        included.rows.firstWhere((r) => r.id == 'activity:${xuexi.id}')
            .totalDuration,
        const Duration(hours: 1),
      );
      expect(
        included.rows.where((r) => r.id == 'activity:${auto.id}'),
        isNotEmpty,
        reason: '开关默认关 = 自动条目计入聚合（极性回归锁）',
      );
      expect(included.totalDuration, const Duration(hours: 1, minutes: 20));

      final excluded = await container
          .read(statsProvider(query(includeAuto: false)).future);
      expect(excluded.rows.where((r) => r.id == 'activity:${auto.id}'), isEmpty);
      expect(
        excluded.rows.firstWhere((r) => r.id == 'activity:${xuexi.id}')
            .totalDuration,
        const Duration(hours: 1),
      );
      expect(excluded.totalDuration, const Duration(hours: 1));
    });

    test('写库 + bump 修订号 → 同键统计重新计算（无需换 query）', () async {
      final container = createTestContainer();
      await pumpAppStore(container);
      final today = DateTime.now().startOfDay;
      final query = StatsQuery(
        start: today,
        end: today.add(const Duration(days: 1)),
        dimension: StatsDimension.activity,
        includeAuto: true,
      );

      // keepAlive 一个监听：family 键不变时才能观察失效重算。
      final sub = container.listen(statsProvider(query), (_, _) {});
      addTearDown(sub.close);

      final empty = await container.read(statsProvider(query).future);
      expect(empty.rows, isEmpty);
      expect(empty.totalDuration, Duration.zero);

      final activities = await container.read(activitiesProvider.future);
      final target = activities.firstWhere((a) => !a.isUnassigned);
      final created = await container
          .read(timeEntryRepositoryProvider)
          .createManualEntry(
            activityId: target.id,
            startAt: today.add(const Duration(hours: 9)),
            endAt: today.add(const Duration(hours: 10)),
            note: '',
          );
      expect(created.isSuccess, isTrue);
      container.read(dataRevisionProvider.notifier).bump();

      final refreshed = await container.read(statsProvider(query).future);
      expect(refreshed.rows, hasLength(1));
      expect(refreshed.rows.single.id, 'activity:${target.id}');
      expect(refreshed.totalDuration, const Duration(hours: 1));
    });

    test('StatsQuery 值键：过滤集合顺序无关、空集与 null 等价', () {
      final start = DateTime(2026, 10, 23);
      final end = start.add(const Duration(days: 1));
      StatsQuery q(Set<String>? ids) => StatsQuery(
            start: start,
            end: end,
            dimension: StatsDimension.activity,
            includeAuto: true,
            categoryFilterIds: ids,
          );

      expect(q({'a', 'b'}), q({'b', 'a'}));
      expect(q({'a', 'b'}).hashCode, q({'b', 'a'}).hashCode);
      expect(q(null), q(<String>{}));
      expect(q(null), isNot(q({'a'})));
    });
  });
}
