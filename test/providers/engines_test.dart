import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/update/update_manifest_service.dart';
import 'package:timetrack2/data/database/app_database.dart';
import 'package:timetrack2/providers/bootstrap.dart';
import 'package:timetrack2/providers/data.dart';
import 'package:timetrack2/providers/engines.dart';
import 'package:timetrack2/stores/update_store.dart' show UpdateState;
import 'package:timetrack2/utils/result.dart';

import '../support/provider_harness.dart';

/// fake 清单服务：真构造 + 覆写 checkForUpdate（不触达网络）。
class _FakeManifestService extends UpdateManifestService {
  _FakeManifestService(AppDatabase db)
      : super(database: db, currentVersion: '0.1.0');

  @override
  Future<AppResult<UpdateCheckResult>> checkForUpdate() async => AppSuccess(
        UpdateCheckResult(
          available: true,
          latestVersion: '0.2.0',
          required: false,
          releaseNotes: '',
          windows: null,
          android: null,
        ),
      );
}

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

    test('updateSnapshot 与 updateChange 双挂载并存（回归：单槽覆盖断更）', () async {
      // 迁移审查 High：UpdateStore.onChanged 单槽曾被 updateSnapshotProvider
      // 与 updateChangeProvider 先后覆盖——后挂者独占通知，先挂的壳层镜像
      // （强制更新对话框/更新 Snackbar）静默失效。改监听表后两者必须并存收讯。
      final db = createTestDatabase();
      addTearDown(db.close);
      final container = createTestContainer(
        database: db,
        overrides: [
          updateManifestServiceProvider.overrideWithValue(
            _FakeManifestService(db),
          ),
        ],
      );
      final store = await pumpAppStore(container);

      // 壳层先挂（AppShell 启动即 listen updateSnapshotProvider），
      // 设置页后挂（watch updateChangeProvider）——即线上覆盖序。
      final snapshotStates = <UpdateState>[];
      container.listen(
        updateSnapshotProvider,
        (_, next) => snapshotStates.add(next.state),
        fireImmediately: true,
      );
      expect(snapshotStates.single, UpdateState.idle);
      final changeBefore = container.read(updateChangeProvider);

      final result = await store.update.check();
      expect(result.isSuccess, isTrue);

      expect(snapshotStates.last, UpdateState.available);
      expect(
        container.read(updateSnapshotProvider).latestVersion,
        '0.2.0',
      );
      expect(
        container.read(updateChangeProvider),
        greaterThan(changeBefore),
      );
    });
  });
}


