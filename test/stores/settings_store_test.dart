import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/data/repositories/settings_repository.dart';
import 'package:timetrack2/stores/data_revision.dart';
import 'package:timetrack2/stores/settings_store.dart';
import 'package:timetrack2/stores/undo_store.dart';
import 'package:timetrack2/viewmodels/profile_settings.dart';

class TestHarness {
  TestHarness() {
    db = AppDatabase(NativeDatabase.memory());
    settings = SettingsRepository(database: db);
    undo = UndoStore();
    revision = DataRevision();
    store = SettingsStore(
      settings: settings,
      undo: undo,
      dataRevision: revision,
    );
  }

  late final AppDatabase db;
  late final SettingsRepository settings;
  late final UndoStore undo;
  late final DataRevision revision;
  late final SettingsStore store;

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return; // 幂等：个别用例手动 dispose 后 tearDown 不重复
    _closed = true;
    store.dispose();
    revision.dispose();
    undo.dispose();
    await db.close();
  }
}

void main() {
  group('SettingsStore', () {
    late TestHarness h;

    setUp(() async {
      h = TestHarness();
      await h.store.reload();
    });
    tearDown(() => h.close());

    test('reload 后读取默认配置', () {
      expect(h.store.current, isNotNull);
      expect(h.store.current!.reminderMinutes,
          ProfileSettings.defaultReminderMinutes);
    });

    test('save：updatedAt 推进到 now + dataRevision 递增', () async {
      final before = h.store.current!;
      // 把 updatedAt 显式拨早（防与 save 内 now 同毫秒 flaky）。
      final baseline = DateTime.now().subtract(const Duration(seconds: 1));
      final withOldStamp = before.copyWith(updatedAt: baseline);
      final beforeRevision = h.revision.value;
      final saved = (await h.store.save(
        withOldStamp.copyWith(reminderMinutes: 30),
      )).requireValue();
      expect(saved.reminderMinutes, 30);
      // updatedAt 必须推进（copyWith 不自动推进——LWW 不丢修改）。
      expect(saved.updatedAt.isAfter(baseline), isTrue);
      expect(h.revision.value, beforeRevision + 1);
    });

    test('save undo：恢复旧配置', () async {
      final before = h.store.current!;
      await h.store.save(before.copyWith(reminderMinutes: 90));
      expect((await h.undo.undo()).isSuccess, isTrue);
      await h.store.reload(); // undo 恢复写库后 reload 是 fire-and-forget：显式等就绪
      expect(h.store.current!.reminderMinutes, before.reminderMinutes);
      expect((await h.undo.redo()).isSuccess, isTrue);
      await h.store.reload();
      expect(h.store.current!.reminderMinutes, 90);
    });

    test('连续 save：dataRevision 单调递增', () async {
      final before = h.store.current!;
      final start = h.revision.value;
      await h.store.save(before.copyWith(reminderMinutes: 15));
      await h.store.save(before.copyWith(reminderMinutes: 16));
      await h.store.save(before.copyWith(reminderMinutes: 17));
      expect(h.revision.value, start + 3);
    });

    test('undo 基准从库重读：外部直写库（同步）后 save 不丢远端值', () async {
      // 模拟云同步经 applyIfRemoteNewer 直写库（不刷新 _current）。
      final base = h.store.current!;
      final remote = base.copyWith(
        reminderMinutes: 60,
        updatedAt: DateTime.now().add(const Duration(minutes: 5)),
      );
      await h.settings.applyIfRemoteNewer(remote);
      expect(h.store.current!.reminderMinutes, base.reminderMinutes); // _current 未刷新

      // save 一次（库基准应读到 60 而非过期的 base）。显式检查成功防假阳性。
      expect((await h.store.save(base.copyWith(reminderMinutes: 45))).isSuccess,
          isTrue);
      expect((await h.undo.undo()).isSuccess, isTrue);
      await h.store.reload();
      // 撤销应恢复库中的远端值 60（而非过期的 base 值）。
      expect(h.store.current!.reminderMinutes, 60);
    });

    test('undo 空栈返回失败', () async {
      expect((await h.undo.undo()).isSuccess, isFalse);
      expect((await h.undo.redo()).isSuccess, isFalse);
    });

    test('dispose 后 save/reload：不崩不写缓存', () async {
      // 独立实例（避免手动 dispose 后 tearDown 二次 dispose）。
      final store = SettingsStore(
        settings: h.settings,
        undo: h.undo,
        dataRevision: h.revision,
      );
      await store.reload();
      store.dispose();
      final currentBeforeSave = store.current;
      // dispose 后 save 仍完成写库但不触碰已释放 store（await 后查 _disposed）。
      final result = await store.save(currentBeforeSave!.copyWith(reminderMinutes: 60));
      expect(result.isSuccess, isTrue); // 写库本身成功
      expect(store.current, currentBeforeSave); // 不写缓存：_current 保持 dispose 前快照
      await store.reload(); // dispose 后静默返回（不崩）
    });
  });
}
