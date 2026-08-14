import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/data/database/app_database.dart' hide ProfileSettings;
import 'package:timetrack2/data/repositories/activity_repository.dart';
import 'package:timetrack2/data/repositories/category_repository.dart';
import 'package:timetrack2/stores/category_store.dart';
import 'package:timetrack2/stores/data_revision.dart';
import 'package:timetrack2/stores/undo_store.dart';
import 'package:timetrack2/utils/result.dart';

class TestHarness {
  TestHarness() {
    db = AppDatabase(NativeDatabase.memory());
    activities = ActivityRepository(database: db);
    categories = CategoryRepository(database: db);
    undo = UndoStore();
    revision = DataRevision();
    store = CategoryStore(
      categories: categories,
      undo: undo,
      dataRevision: revision,
    );
  }

  late final AppDatabase db;
  late final ActivityRepository activities;
  late final CategoryRepository categories;
  late final UndoStore undo;
  late final DataRevision revision;
  late final CategoryStore store;

  /// 等待 store 缓存就绪（写路径 reload 是 fire-and-forget）。
  Future<void> settleCache() => store.reload();

  Future<void> close() async {
    store.dispose();
    revision.dispose();
    undo.dispose();
    await db.close();
  }
}

void main() {
  group('CategoryStore 树缓存', () {
    late TestHarness h;

    setUp(() async {
      h = TestHarness();
      await h.settleCache();
    });
    tearDown(() => h.close());

    test('树索引：childrenByParent / ancestorChains / descendantsOf', () async {
      final root = (await h.store.createCategory(name: '工作', color: 0))
          .requireValue();
      final child = (await h.store.createCategory(
        name: '项目A',
        color: 0,
        parentId: root.id,
      )).requireValue();
      final grand = (await h.store.createCategory(
        name: '子项',
        color: 0,
        parentId: child.id,
      )).requireValue();
      // 写路径的 reload 是 fire-and-forget：断言前显式 await 缓存就绪。
      await h.settleCache();

      expect(h.store.childrenByParent[null]!.map((c) => c.id), [root.id]);
      expect(h.store.childrenByParent[root.id]!.map((c) => c.id), [child.id]);
      expect(h.store.childrenByParent[child.id]!.map((c) => c.id), [grand.id]);
      expect(h.store.ancestorChains[child.id], [root.id]);
      expect(h.store.ancestorChains[grand.id], [root.id, child.id]);
      expect(h.store.ancestorChains[root.id], isEmpty);
      expect(h.store.descendantsOf[root.id], {root.id, child.id, grand.id});
      expect(h.store.descendantsOf[child.id], {child.id, grand.id});
      expect(h.store.categoryById[root.id]?.name, '工作');
    });

    test('createCategory：dataRevision 递增', () async {
      final before = h.revision.value;
      await h.store.createCategory(name: 'X', color: 0);
      expect(h.revision.value, before + 1);
    });
  });

  group('CategoryStore 写路径 + undo', () {
    late TestHarness h;

    setUp(() async {
      h = TestHarness();
      await h.settleCache();
    });
    tearDown(() => h.close());

    test('新建分类 undo：软删；redo：恢复', () async {
      final created = (await h.store.createCategory(name: 'X', color: 0))
          .requireValue();
      await h.undo.undo();
      final afterUndo =
          (await h.categories.categoryByIdIncludingDeleted(created.id))!;
      expect(afterUndo.isDeleted, isTrue);
      await h.undo.redo();
      final afterRedo =
          (await h.categories.categoryByIdIncludingDeleted(created.id))!;
      expect(afterRedo.isDeleted, isFalse);
    });

    test('修改分类 undo：恢复旧快照', () async {
      final created = (await h.store.createCategory(name: 'X', color: 0))
          .requireValue();
      await h.store.updateCategory(
        category: created,
        name: 'Y',
        color: 0x112233,
      );
      await h.undo.undo();
      final restored =
          (await h.categories.categoryByIdIncludingDeleted(created.id))!;
      expect(restored.name, 'X');
      expect(restored.color, 0);
    });

    test('递归级联删除 undo：整条记录一次恢复（计划风险 10）', () async {
      // 用仓储 seed（不走 store 写路径，避免 undo 栈被 seed 污染）。
      final root = (await h.categories.createCategory(name: '工作', color: 0))
          .requireValue();
      final child = (await h.categories.createCategory(
        name: '项目A',
        color: 0,
        parentId: root.id,
      )).requireValue();
      final grand = (await h.categories.createCategory(
        name: '子项',
        color: 0,
        parentId: child.id,
      )).requireValue();
      final activity = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      await h.categories.setActivityCategories(
        activityId: activity.id,
        primaryCategoryId: grand.id,
      );
      expect(h.undo.undoDepth, 0); // seed 不入 undo 栈
      await h.settleCache(); // 同步 store 缓存

      final deletion = (await h.store.deleteCategory(root.id)).requireValue();
      expect(deletion.categories, hasLength(3)); // root+child+grand
      expect(deletion.links, isNotEmpty);
      expect(h.undo.undoDepth, 1); // 级联删除 = 一条 undo 记录
      expect(h.undo.lastUndoLabel, '删除分类');

      await h.undo.undo(); // 一次性复活全部
      final rootBack =
          (await h.categories.categoryByIdIncludingDeleted(root.id))!;
      final childBack =
          (await h.categories.categoryByIdIncludingDeleted(child.id))!;
      final grandBack =
          (await h.categories.categoryByIdIncludingDeleted(grand.id))!;
      expect(rootBack.isDeleted, isFalse);
      expect(childBack.isDeleted, isFalse);
      expect(grandBack.isDeleted, isFalse);
      expect(
          (await h.categories.links()).requireValue(), isNotEmpty); // 链接复活

      await h.undo.redo(); // 重软删全部
      expect(
          (await h.categories.categoryByIdIncludingDeleted(root.id))!.isDeleted,
          isTrue);
      expect(
          (await h.categories.categoryByIdIncludingDeleted(child.id))!.isDeleted,
          isTrue);
      expect(
          (await h.categories.categoryByIdIncludingDeleted(grand.id))!.isDeleted,
          isTrue);
    });

    test('删除分类后树缓存重建（无残留）', () async {
      final root = (await h.store.createCategory(name: '工作', color: 0))
          .requireValue();
      final child = (await h.store.createCategory(
        name: '项目A',
        color: 0,
        parentId: root.id,
      )).requireValue();
      await h.store.deleteCategory(root.id);
      await h.settleCache(); // 写路径 reload 是 fire-and-forget：显式等就绪
      expect(h.store.all, isEmpty);
      expect(h.store.childrenByParent[null], isNull);
      expect(h.store.descendantsOf[child.id], isNull);
    });

    test('setActivityCategories undo：恢复旧链接集', () async {
      final activity = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final c1 = (await h.store.createCategory(name: 'c1', color: 0))
          .requireValue();
      final c2 = (await h.store.createCategory(name: 'c2', color: 0))
          .requireValue();
      await h.categories.setActivityCategories(
        activityId: activity.id,
        primaryCategoryId: c1.id,
        secondaryCategoryIds: [c2.id],
      );
      await h.store.setActivityCategories(
        activityId: activity.id,
        primaryCategoryId: c2.id, // 换主 + 移除 c1
      );

      await h.undo.undo(); // 恢复旧链接集（c1 主 + c2 次）
      final links = (await h.categories.links()).requireValue()
          .where((l) => l.activityId == activity.id)
          .toList();
      expect(links.map((l) => l.categoryId), containsAll([c1.id, c2.id]));
      expect(links.firstWhere((l) => l.categoryId == c1.id).isPrimary, isTrue);
    });

    test('setActivityCategories 首次分配 undo：新建链接被移除', () async {
      final activity = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final c1 = (await h.store.createCategory(name: 'c1', color: 0))
          .requireValue();
      // 首次分配（oldLinks 为空）：undo 须移除新建链接（防残留）。
      final saved = (await h.store.setActivityCategories(
        activityId: activity.id,
        primaryCategoryId: c1.id,
      )).requireValue();
      expect(saved, hasLength(1));

      await h.undo.undo();
      final afterUndo = (await h.categories.links(includeDeleted: true))
          .requireValue()
          .where((l) => l.activityId == activity.id)
          .toList();
      // 新建链接被软删（includeDeleted 列表含软删行——断言无激活链接）。
      expect(afterUndo.where((l) => !l.isDeleted), isEmpty);
      expect(afterUndo, hasLength(1)); // 软删行留存（LWW 传播语义）

      await h.undo.redo();
      final afterRedo = (await h.categories.links(includeDeleted: true))
          .requireValue()
          .where((l) => l.activityId == activity.id && !l.isDeleted)
          .toList();
      expect(afterRedo, hasLength(1)); // redo 恢复新链接集
    });

    test('setActivityCategories 重新激活旧链接 redo：保持激活态', () async {
      final activity = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final c1 = (await h.store.createCategory(name: 'c1', color: 0))
          .requireValue();
      await h.store.setActivityCategories(
        activityId: activity.id,
        primaryCategoryId: c1.id,
      );
      // 第二次：移除 c1（旧链接被软删），再恢复（重新激活）。
      await h.store.setActivityCategories(activityId: activity.id);
      await h.store.setActivityCategories(
        activityId: activity.id,
        primaryCategoryId: c1.id,
      );
      await h.undo.undo(); // 回到"移除 c1"（c1 软删）
      await h.undo.undo(); // 回到"首次分配"（c1 激活）
      // redo 两次：第一次重新激活（redo 写回新链接集含激活态），
      // 第二次保持激活。
      await h.undo.redo();
      await h.undo.redo();
      final active = (await h.categories.links())
          .requireValue()
          .where((l) => l.activityId == activity.id)
          .toList();
      expect(active, hasLength(1)); // c1 保持激活（未被误软删）
      expect(active.single.isDeleted, isFalse);
    });

    test('缓存集合不可变（外部篡改抛错）', () async {
      await h.store.createCategory(name: 'X', color: 0);
      await h.settleCache();
      expect(
        () => h.store.all.add(h.store.all.first),
        throwsUnsupportedError,
      );
      expect(
        () => h.store.categoryById['missing'] = h.store.categoryById.values.first,
        throwsUnsupportedError,
      );
    });
  });

  group('CategoryRepository.restoreCategoryStatesForUndo（直接）', () {
    late TestHarness h;

    setUp(() async {
      h = TestHarness();
      await h.settleCache();
    });
    tearDown(() => h.close());

    test('单事务恢复：分类+links 混排原子生效', () async {
      final root = (await h.categories.createCategory(name: '工作', color: 0))
          .requireValue();
      final child = (await h.categories.createCategory(
        name: '项目A',
        color: 0,
        parentId: root.id,
      )).requireValue();
      final activity = (await h.activities.createActivity(name: 'A', color: 0))
          .requireValue();
      final saved = (await h.categories.setActivityCategories(
        activityId: activity.id,
        primaryCategoryId: child.id,
      )).requireValue();
      // 软删 root（级联）后，直接调用恢复（绕过 store/undo 栈）。
      await h.categories.deleteCategory(root);

      final result = await h.categories.restoreCategoryStatesForUndo(
        [
          (entry: root, softDelete: false),
          (entry: child, softDelete: false),
        ],
        [
          for (final l in saved) (entry: l, softDelete: false),
        ],
      );
      expect(result, isA<AppSuccess<void>>());
      expect(
          (await h.categories.categoryByIdIncludingDeleted(root.id))!.isDeleted,
          isFalse);
      expect(
          (await h.categories.categoryByIdIncludingDeleted(child.id))!.isDeleted,
          isFalse);
      expect((await h.categories.links()).requireValue(), isNotEmpty);
    });

    test('空列表调用：无操作成功返回', () async {
      final result = await h.categories.restoreCategoryStatesForUndo(
        const [],
        const [],
      );
      expect(result, isA<AppSuccess<void>>());
    });

    test('softDelete=true：重软删已复活行', () async {
      final root = (await h.categories.createCategory(name: '工作', color: 0))
          .requireValue();
      await h.categories.restoreCategoryStatesForUndo(
        [(entry: root, softDelete: false)],
        const [],
      );
      await h.categories.restoreCategoryStatesForUndo(
        [(entry: root, softDelete: true)],
        const [],
      );
      expect(
          (await h.categories.categoryByIdIncludingDeleted(root.id))!.isDeleted,
          isTrue);
    });
  });
}
