import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/stores/undo_store.dart';
import 'package:timetrack2/utils/result.dart';

/// 可配置的假写库契约：记录 validate/apply 收到的值，可按需注入失败。
class _FakeApplier implements UndoApplier {
  _FakeApplier({this.validateFails = false, this.applyFails = false});

  /// validate 是否失败（模拟"当前库状态与记录不符"冲突）。
  bool validateFails;

  /// apply 是否失败（模拟写库异常；实现正常不该发生，防御验证）。
  bool applyFails;

  /// apply 前的回调（模拟恢复写库触发的副作用，测试执行期保护）。
  void Function()? onApply;

  final validated = <Object?>[];
  final applied = <Object?>[];

  @override
  Future<AppResult<void>> validate(Object? expected) async {
    if (validateFails) return const AppFailure('冲突：数据已被修改');
    validated.add(expected);
    return const AppSuccess(null);
  }

  @override
  Future<AppResult<void>> apply(Object? target) async {
    onApply?.call();
    if (applyFails) return const AppFailure('写库失败');
    applied.add(target);
    return const AppSuccess(null);
  }
}

void main() {
  group('UndoStore', () {
    late UndoStore store;

    setUp(() => store = UndoStore());
    tearDown(() => store.dispose());

    test('undo 校验 after（最近状态）并应用 before；redo 对称', () async {
      final applier = _FakeApplier();
      store.record(
        label: 'op',
        changes: [UndoChange(before: 'B', after: 'A', applier: applier)],
      );

      final undoResult = await store.undo();
      expect(undoResult, isA<AppSuccess<void>>());
      expect(applier.validated, ['A']); // undo 先校验"当前 == 操作后状态"
      expect(applier.applied, ['B']); //   undo 再应用操作前状态

      final redoResult = await store.redo();
      expect(redoResult, isA<AppSuccess<void>>());
      expect(applier.validated, ['A', 'B']); // redo 校验"当前 == 操作前状态"
      expect(applier.applied, ['B', 'A']); //   redo 应用操作后状态
    });

    test('LIFO：后记录的先撤销', () async {
      final a = _FakeApplier();
      final b = _FakeApplier();
      store.record(
        label: 'A',
        changes: [UndoChange(before: 'B1', after: 'A1', applier: a)],
      );
      store.record(
        label: 'B',
        changes: [UndoChange(before: 'B2', after: 'A2', applier: b)],
      );

      expect(store.lastUndoLabel, 'B');
      await store.undo();
      expect(b.applied, ['B2']);
      await store.undo();
      expect(a.applied, ['B1']);
      expect(store.canUndo, isFalse);
      expect(store.canRedo, isTrue); // 两条都迁移到 redo
      expect(store.lastRedoLabel, 'A');
    });

    test('新操作清空 redo 栈', () async {
      final a = _FakeApplier();
      final b = _FakeApplier();
      store.record(
        label: 'A',
        changes: [UndoChange(before: 'B1', after: 'A1', applier: a)],
      );
      await store.undo();
      expect(store.canRedo, isTrue);

      store.record(
        label: 'B',
        changes: [UndoChange(before: 'B2', after: 'A2', applier: b)],
      );
      expect(store.canRedo, isFalse); // 新操作清空 redo
      expect(store.lastUndoLabel, 'B');

      final redoResult = await store.redo();
      expect(redoResult, isA<AppFailure<void>>());
    });

    test('深度超限丢最旧', () async {
      final store = UndoStore(maxDepth: 2);
      final applier = _FakeApplier();
      for (var i = 0; i < 3; i++) {
        store.record(
          label: 'op$i',
          changes: [UndoChange(before: 'B$i', after: 'A$i', applier: applier)],
        );
      }
      expect(store.undoDepth, 2);
      expect(store.lastUndoLabel, 'op2');

      await store.undo();
      expect(applier.applied, ['B2']); // undo 应用操作前状态（before）
      await store.undo();
      expect(applier.applied, ['B2', 'B1']);

      final result = await store.undo(); // op0 已被丢弃
      expect(result, isA<AppFailure<void>>());
      store.dispose();
    });

    test('两阶段：任一 validate 失败则整组拒绝、不 apply、栈不动', () async {
      final ok = _FakeApplier();
      final bad = _FakeApplier(validateFails: true);
      // 模拟级联删除：父分类 + 子分类两条 change（一条记录）。
      store.record(
        label: '删除分类',
        changes: [
          UndoChange(before: 'cat', after: null, applier: ok),
          UndoChange(before: 'sub', after: null, applier: bad),
        ],
      );

      final result = await store.undo();
      expect(result, isA<AppFailure<void>>());
      // 校验阶段顺序执行：第 1 个 change（ok）被校验并记录 expected；
      // bad 的 validate 在失败分支直接返回、未记录（bad.validated 为空）。
      expect(ok.validated, [null]);
      expect(bad.validated, isEmpty);
      // 任一失败 → 第 1 个也未被 apply（防 undo 半恢复）。
      expect(ok.applied, isEmpty);
      // 栈不动：记录留在 undo 栈、未迁移到 redo。
      expect(store.canUndo, isTrue);
      expect(store.canRedo, isFalse);
      expect(store.lastUndoLabel, '删除分类');
    });

    test('apply 失败：记录不迁移（保留在源栈，可重试）', () async {
      final failing = _FakeApplier(applyFails: true);
      store.record(
        label: 'op',
        changes: [UndoChange(before: 'B', after: 'A', applier: failing)],
      );

      final result = await store.undo();
      expect(result, isA<AppFailure<void>>());
      expect(store.canUndo, isTrue);
      expect(store.undoDepth, 1);
      expect(store.canRedo, isFalse);
    });

    test('空栈 undo/redo 返回失败', () async {
      expect(await store.undo(), isA<AppFailure<void>>());
      expect(await store.redo(), isA<AppFailure<void>>());
    });

    test('undo 执行期触发的 record 被忽略（防误清 redo）', () async {
      final spurious = _FakeApplier();
      final spying = _FakeApplier()
        ..onApply = () {
          // 恢复写库副作用路径：意外触发 record 必须被忽略。
          store.record(
            label: 'spurious',
            changes: [UndoChange(before: 'X', after: 'Y', applier: spurious)],
          );
        };
      store.record(
        label: 'op',
        changes: [UndoChange(before: 'B', after: 'A', applier: spying)],
      );

      await store.undo();
      expect(spurious.applied, isEmpty); // spurious 未入栈执行
      expect(store.canUndo, isFalse); //   undo 栈只剩 op（已迁移）
      expect(store.canRedo, isTrue); //    redo 栈未被清空
      expect(store.lastRedoLabel, 'op');
      expect(store.redoDepth, 1);
    });

    test('record/undo/redo 各触发一次通知', () async {
      var notifications = 0;
      store.addListener(() => notifications++);

      store.record(
        label: 'op',
        changes: [
          UndoChange(before: 'B', after: 'A', applier: _FakeApplier()),
        ],
      );
      expect(notifications, 1);
      await store.undo();
      expect(notifications, 2);
      await store.redo();
      expect(notifications, 3);
    });

    test('label 访问器随栈迁移更新', () async {
      expect(store.lastUndoLabel, isNull);
      expect(store.lastRedoLabel, isNull);
      store.record(
        label: 'switch',
        changes: [UndoChange(before: 'B', after: 'A', applier: _FakeApplier())],
      );
      expect(store.lastUndoLabel, 'switch');
      await store.undo();
      expect(store.lastUndoLabel, isNull);
      expect(store.lastRedoLabel, 'switch');
    });

    test('空 changes 记录被拒绝（编程错误）', () {
      expect(() => store.record(label: 'x', changes: []), throwsArgumentError);
    });
  });
}
