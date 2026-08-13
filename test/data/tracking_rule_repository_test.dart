import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/data/database/app_database.dart';
import 'package:timetrack2/data/repositories/tracking_rule_repository.dart';
import 'package:timetrack2/viewmodels/tracking_rule.dart';

/// 内存库测试：TrackingRuleRepository（模块 2c'）。
void main() {
  group('TrackingRule 仓储', () {
    late AppDatabase db;
    late TrackingRuleRepository repo;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = TrackingRuleRepository(database: db);
      // 规则 activity_id 引用 activities（FK ON）——先建活动，防插入失败
      //（与 activity_category_links 测试同模式）。
      await db.into(db.activities).insert(ActivitiesCompanion.insert(
        id: 'a1',
        userId: const Value(null),
        name: '规则活动',
        color: 0xff2563eb,
        isFavorite: const Value(false),
        updatedAt: '2026-08-12T04:00:00.000000Z',
      ));
    });

    tearDown(() => db.close());

    TrackingRule rule({
      String id = 'r1',
      String? userId,
      String pattern = 'chrome.exe',
      TrackingRuleMatchKind kind = TrackingRuleMatchKind.process,
      String activityId = 'a1',
      bool syncEnabled = true,
      DateTime? updatedAt,
      DateTime? deletedAt,
    }) =>
        TrackingRule(
          id: id,
          userId: userId,
          pattern: pattern,
          matchKind: kind,
          activityId: activityId,
          syncEnabled: syncEnabled,
          updatedAt: updatedAt ?? DateTime.utc(2026, 8, 12, 4),
          deletedAt: deletedAt,
        );

    test('save → activeRules/allRules round-trip 保真（含 sync_enabled=false）', () async {
      final localOnly = rule(id: 'r-local', syncEnabled: false);
      final synced = rule(id: 'r-sync', syncEnabled: true);
      expect((await repo.saveRule(localOnly)).isSuccess, isTrue);
      expect((await repo.saveRule(synced)).isSuccess, isTrue);

      final active = (await repo.activeRules()).requireValue();
      expect(active.map((r) => r.id), containsAll(['r-local', 'r-sync']));
      final restored = active.firstWhere((r) => r.id == 'r-local');
      expect(restored.syncEnabled, isFalse, reason: 'sync_enabled=false 保真');
      expect(restored.pattern, 'chrome.exe');
      expect(restored.matchKind, TrackingRuleMatchKind.process);
      expect(restored.activityId, 'a1');

      final all = (await repo.allRules()).requireValue();
      expect(all.map((r) => r.id), containsAll(['r-local', 'r-sync']));
    });

    test('软删：deleteRule 置 deleted_at 推进 updated_at（LWW 删除永远赢）', () async {
      final saved = rule(updatedAt: DateTime.utc(2026, 8, 12, 4));
      await repo.saveRule(saved);
      await repo.deleteRule(saved);
      // activeRules 不含已删行
      expect((await repo.activeRules()).requireValue(), isEmpty);
      // allRules 含已删行且标记软删（防实现退化为物理删除）
      final all = (await repo.allRules()).requireValue();
      final tombstone = all.single;
      expect(tombstone.isDeleted, isTrue, reason: '墓碑行保留且标记软删');
      expect(tombstone.deletedAt, isNotNull);
      expect(
        tombstone.updatedAt.isAfter(saved.updatedAt),
        isTrue,
        reason: '墓碑推进 updated_at（删除永远赢）',
      );
    });

    test('rulesSince：仅返回 sync_enabled=true 且 updated_at >= since（行级过滤）', () async {
      final t0 = DateTime.utc(2026, 8, 12, 4);
      await repo.saveRule(rule(id: 'r-sync-new', updatedAt: t0, syncEnabled: true));
      // 本地-only 规则（sync_enabled=false）：即使晚于 since 也不返回（不进远端）
      await repo.saveRule(
        rule(id: 'r-local-new', updatedAt: t0.add(const Duration(minutes: 1)), syncEnabled: false),
      );
      // 早于 since 的同步规则：不返回
      await repo.saveRule(
        rule(id: 'r-sync-old', updatedAt: t0.subtract(const Duration(hours: 1)), syncEnabled: true),
      );
      // 已删的同步规则：不返回（软删行不进远端——删除在本地完成，远端删除靠
      // 墓碑传播语义，但本表同步规则删除后由下次同步以 LWW 删除永远赢处理；
      // 被删行 updated_at 已推进，若晚于 since 应返回墓碑行供远端删除）。
      // ——此处显式验证：已删行在窗口内应返回（墓碑传播），见下一用例。

      final result = (await repo.rulesSince(t0)).requireValue();
      expect(result.map((r) => r.id), ['r-sync-new'],
          reason: '仅 sync_enabled=true 且晚于 since 的规则进入增量窗口');
    });

    test('rulesSince 窗口内已删同步规则返回墓碑（远端删除传播）', () async {
      final t0 = DateTime.utc(2026, 8, 12, 4);
      final saved = rule(id: 'r-del', updatedAt: t0);
      await repo.saveRule(saved);
      await repo.deleteRule(saved); // updatedAt 推进到 now（> t0）
      final result = (await repo.rulesSince(t0)).requireValue();
      expect(result, hasLength(1), reason: '已删同步规则以墓碑行进入增量窗口');
      expect(result.single.isDeleted, isTrue,
          reason: '墓碑行携带 deleted_at（远端 LWW 删除永远赢）');
    });

    test('replaceIfRemoteNewer LWW：远端更旧不覆盖 / 更晚覆盖 / 平局删除墓碑胜出', () async {
      final t0 = DateTime.utc(2026, 8, 12, 4);
      final local = rule(id: 'r1', updatedAt: t0);
      await repo.saveRule(local);

      // 远端更旧：不覆盖
      final stale = rule(
        id: 'r1',
        pattern: 'stale.exe',
        updatedAt: t0.subtract(const Duration(minutes: 1)),
      );
      await repo.replaceIfRemoteNewer(stale);
      expect((await repo.ruleById('r1'))!.pattern, 'chrome.exe',
          reason: '远端更旧不覆盖');

      // 远端更晚：覆盖
      final newer = rule(
        id: 'r1',
        pattern: 'newer.exe',
        updatedAt: t0.add(const Duration(minutes: 1)),
      );
      await repo.replaceIfRemoteNewer(newer);
      expect((await repo.ruleById('r1'))!.pattern, 'newer.exe',
          reason: '远端更晚覆盖');

      // 平局 + 远端删除墓碑：删除永远赢
      final tieTombstone = rule(
        id: 'r1',
        updatedAt: t0.add(const Duration(minutes: 1)),
        deletedAt: t0.add(const Duration(minutes: 1)),
      );
      await repo.replaceIfRemoteNewer(tieTombstone);
      final after = await repo.ruleById('r1');
      expect(after!.isDeleted, isTrue, reason: '平局时间戳远端墓碑胜出（删除永远赢）');
    });
  });
}
