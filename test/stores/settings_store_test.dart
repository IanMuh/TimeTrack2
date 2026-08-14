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

  Future<void> close() async {
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
      final beforeRevision = h.revision.value;
      final saved = (await h.store.save(
        before.copyWith(reminderMinutes: 30),
      )).requireValue();
      expect(saved.reminderMinutes, 30);
      // updatedAt 必须推进（copyWith 不自动推进——LWW 不丢修改）。
      expect(saved.updatedAt.isAfter(before.updatedAt), isTrue);
      expect(h.revision.value, beforeRevision + 1);
    });

    test('save undo：恢复旧配置', () async {
      final before = h.store.current!;
      await h.store.save(before.copyWith(reminderMinutes: 90));
      await h.undo.undo();
      await h.store.reload(); // undo 恢复写库后 reload 是 fire-and-forget：显式等就绪
      expect(h.store.current!.reminderMinutes, before.reminderMinutes);
      await h.undo.redo();
      await h.store.reload();
      expect(h.store.current!.reminderMinutes, 90);
    });
  });
}
