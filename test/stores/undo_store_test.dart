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

  /// validate 前回调（模拟校验期间触发新 record，测试恢复期防护）。
  void Function()? onValidate;

  /// apply 前的回调（模拟恢复写库触发的副作用，测试执行期保护）。
  void Function()? onApply;

  final validated = <Object?>[];
  final applied = <Object?>[];

  @override
  Future<AppResult<void>> validate(Object? expected) async {
    onValidate?.call();
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

/// 契约外行为：validate/apply 抛未归约异常（模拟连接错误等）。
class _ThrowingApplier implements UndoApplier {
  _ThrowingApplier({this.throwOnValidate = true});

  /// validate 是否抛异常；apply 恒抛（覆盖 apply 抛异常路径时用
  /// `throwOnValidate: false` 让校验通过）。
  final bool throwOnValidate;

  @override
  Future<AppResult<void>> validate(Object? expected) async {
    if (throwOnValidate) throw StateError('网络中断');
    return const AppSuccess(null);
  }

  @override
  Future<AppResult<void>> apply(Object? target) async {
    throw StateError('网络中断');
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
      final boundedStore = UndoStore(maxDepth: 2);
      final applier = _FakeApplier();
      for (var i = 0; i < 3; i++) {
        boundedStore.record(
          label: 'op$i',
          changes: [UndoChange(before: 'B$i', after: 'A$i', applier: applier)],
        );
      }
      expect(boundedStore.undoDepth, 2);
      expect(boundedStore.lastUndoLabel, 'op2');

      await boundedStore.undo();
      expect(applier.applied, ['B2']); // undo 应用操作前状态（before）
      await boundedStore.undo();
      expect(applier.applied, ['B2', 'B1']);

      final result = await boundedStore.undo(); // op0 已被丢弃
      expect(result, isA<AppFailure<void>>());
      boundedStore.dispose();
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

    test('redo 失败（validate 拒绝）：redo 栈不动、记录可重试', () async {
      final failing = _FakeApplier(); // 初始不失败，保证首次 undo 成功
      store.record(
        label: 'op',
        changes: [UndoChange(before: 'B', after: 'A', applier: failing)],
      );
      await store.undo(); // 先撤销成功 → 记录迁入 redo 栈
      expect(store.canRedo, isTrue);

      failing.validateFails = true; // redo 时校验失败
      final result = await store.redo();
      expect(result, isA<AppFailure<void>>());
      // redo 失败：redo 栈不动（记录未被弹出/迁移回 undo），可重试。
      expect(store.canRedo, isTrue);
      expect(store.redoDepth, 1);
      expect(store.canUndo, isFalse);
      expect(store.lastRedoLabel, 'op');
    });

    test('redo 失败（apply 失败）：redo 栈不动', () async {
      final failing = _FakeApplier(); // 初始不失败，保证首次 undo 成功
      store.record(
        label: 'op',
        changes: [UndoChange(before: 'B', after: 'A', applier: failing)],
      );
      await store.undo();
      expect(store.canRedo, isTrue);

      failing.applyFails = true; // redo 时 apply 失败
      final result = await store.redo();
      expect(result, isA<AppFailure<void>>());
      expect(store.canRedo, isTrue);
      expect(store.redoDepth, 1);
      expect(store.canUndo, isFalse);
    });

    test('多 change 记录成功恢复：按列表顺序 apply（级联恢复语义）', () async {
      final first = _FakeApplier();
      final second = _FakeApplier();
      store.record(
        label: '删除分类',
        changes: [
          UndoChange(before: 'cat', after: null, applier: first),
          UndoChange(before: 'sub', after: null, applier: second),
        ],
      );
      await store.undo();
      expect(first.applied, ['cat']);
      expect(second.applied, ['sub']);
      expect(first.validated, [null]);
      expect(second.validated, [null]);
      await store.redo();
      expect(first.applied, ['cat', null]); // redo 应用 after（null = 删除）
      expect(second.applied, ['sub', null]);
    });

    test('validate 异步阶段触发的 record 被忽略（防栈错位）', () async {
      final newOp = _FakeApplier();
      // validate 挂起（异步回调内触发新 record）：恢复期间 record 必须被忽略，
      // 否则新记录入栈 → source.removeLast() 弹出新记录而非本次恢复的记录。
      final asyncApplier = _FakeApplier()
        ..onValidate = () {
          store.record(
            label: 'new',
            changes: [UndoChange(before: 'X', after: 'Y', applier: newOp)],
          );
        };
      store.record(
        label: 'op',
        changes: [UndoChange(before: 'B', after: 'A', applier: asyncApplier)],
      );

      final result = await store.undo();
      expect(result, isA<AppSuccess<void>>());
      expect(asyncApplier.applied, ['B']); // 本次恢复的记录被正确应用
      expect(newOp.applied, isEmpty); //     validate 期 record 未入栈执行
      expect(store.canUndo, isFalse); //     undo 栈只剩 op（已迁移）
      expect(store.canRedo, isTrue); //      redo 未被新记录清空
      expect(store.redoDepth, 1);
    });

    test('并发 undo：仅第一个执行，第二个被互斥拒绝', () async {
      final applier = _FakeApplier();
      store.record(
        label: 'op',
        changes: [UndoChange(before: 'B', after: 'A', applier: applier)],
      );

      final results = await Future.wait([store.undo(), store.undo()]);
      expect(results.whereType<AppSuccess<void>>(), hasLength(1));
      expect(results.whereType<AppFailure<void>>(), hasLength(1));
      // 唯一成功的那次：记录迁移到 redo，仅应用一次。
      expect(applier.applied, ['B']);
      expect(store.canUndo, isFalse);
      expect(store.canRedo, isTrue);
      expect(store.redoDepth, 1);
    });

    test('applier 抛异常（契约外）：转为 AppFailure，不逃逸为异步 error', () async {
      // validate 抛异常 → undo 返回 AppFailure（而不是 Future 以 error 结束）。
      final validateThrowing = _ThrowingApplier();
      store.record(
        label: 'op',
        changes: [UndoChange(before: 'B', after: 'A', applier: validateThrowing)],
      );
      final validateResult = await store.undo();
      expect(validateResult, isA<AppFailure<void>>());
      expect(store.canUndo, isTrue); // 栈不动
      expect(store.canRedo, isFalse);

      // apply 抛异常 → undo 同样收敛为 AppFailure。
      final applyThrowing = _ThrowingApplier(throwOnValidate: false);
      store.record(
        label: 'op2',
        changes: [UndoChange(before: 'B2', after: 'A2', applier: applyThrowing)],
      );
      final applyResult = await store.undo();
      expect(applyResult, isA<AppFailure<void>>());
      expect(store.canUndo, isTrue); // 栈不动（op2 仍在，op 也仍在）
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
