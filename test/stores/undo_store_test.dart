import 'dart:async';

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

/// 契约外行为：validate/apply 抛未归约 **Exception**（模拟连接错误等；
/// Error 类编程错误由 fail-fast 外抛路径覆盖，见对应测试）。
class _ThrowingApplier implements UndoApplier {
  _ThrowingApplier({this.throwOnValidate = true});

  /// validate 是否抛异常；apply 恒抛（覆盖 apply 抛异常路径时用
  /// `throwOnValidate: false` 让校验通过）。
  final bool throwOnValidate;

  @override
  Future<AppResult<void>> validate(Object? expected) async {
    if (throwOnValidate) throw Exception('网络中断');
    return const AppSuccess(null);
  }

  @override
  Future<AppResult<void>> apply(Object? target) async {
    throw Exception('网络中断');
  }
}

/// 抛 **Error**（编程错误）：实现不得吞掉，应 fail-fast 外抛。
/// （Dart 中 Error 不实现 Exception，`on Exception catch` 不会捕获它们。）
class _ErrorApplier implements UndoApplier {
  _ErrorApplier({this.throwOnValidate = true});

  /// validate 是否抛 Error；apply 恒抛（覆盖 apply 段 Error fail-fast 时用
  /// `throwOnValidate: false` 让校验通过）。
  final bool throwOnValidate;

  @override
  Future<AppResult<void>> validate(Object? expected) async {
    if (throwOnValidate) throw StateError('applier 实现缺陷');
    return const AppSuccess(null);
  }

  @override
  Future<AppResult<void>> apply(Object? target) async {
    throw StateError('applier 实现缺陷');
  }
}

/// validate 挂起在 [gate] 上直到外部放行：模拟真实异步 I/O 挂起窗口，
/// 覆盖"validate 进行中触发新 record"的并发重入。
class _CompleterApplier implements UndoApplier {
  _CompleterApplier(this._gate);

  final Completer<void> _gate;
  final applied = <Object?>[];

  @override
  Future<AppResult<void>> validate(Object? expected) async {
    await _gate.future;
    return const AppSuccess(null);
  }

  @override
  Future<AppResult<void>> apply(Object? target) async {
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
      expect(store.lastRedoLabel, 'op'); // 与 validate 失败用例对称：可重试
    });

    test('多 change 记录成功恢复：按列表顺序 apply（级联恢复语义）', () async {
      // 用共享执行日志断言真实交错顺序：独立 applied 列表无法区分
      // "先 first 后 second" 与 "先 second 后 first"（各列表断言仍各自通过）。
      final applyLog = <String>[];
      final first = _FakeApplier()..onApply = () => applyLog.add('first');
      final second = _FakeApplier()..onApply = () => applyLog.add('second');
      store.record(
        label: '删除分类',
        changes: [
          UndoChange(before: 'cat', after: null, applier: first),
          UndoChange(before: 'sub', after: null, applier: second),
        ],
      );
      await store.undo();
      expect(applyLog, ['first', 'second']); // 按列表顺序 apply
      expect(first.applied, ['cat']);
      expect(second.applied, ['sub']);
      expect(first.validated, [null]);
      expect(second.validated, [null]);
      await store.redo();
      expect(applyLog, ['first', 'second', 'first', 'second']);
      expect(first.applied, ['cat', null]); // redo 应用 after（null = 删除）
      expect(second.applied, ['sub', null]);
    });

    test('validate 挂起窗口触发的 record 被忽略（真实异步重入）', () async {
      final newOp = _FakeApplier();
      // 用 Completer 让 validate 真正挂起：在挂起窗口内触发新 record，覆盖
      // 真实异步 I/O 重入窗口（而非 validate 的同步段回调）。
      final gate = Completer<void>();
      final asyncApplier = _CompleterApplier(gate);
      store.record(
        label: 'op',
        changes: [UndoChange(before: 'B', after: 'A', applier: asyncApplier)],
      );

      final undoFuture = store.undo(); // validate 挂起在 gate 上
      await pumpEventQueue();
      store.record(
        label: 'new',
        changes: [UndoChange(before: 'X', after: 'Y', applier: newOp)],
      );
      gate.complete(); // 放行 validate → 继续恢复
      final result = await undoFuture;
      expect(result, isA<AppSuccess<void>>());
      expect(asyncApplier.applied, ['B']); // 本次恢复的记录被正确应用
      expect(newOp.applied, isEmpty); //     validate 挂起期 record 被忽略
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

    test('applier 抛 Exception（契约外）：转为 AppFailure，不逃逸为异步 error', () async {
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

    test('applier 抛 Error（编程错误）：fail-fast 外抛，不转为业务失败', () async {
      final errorApplier = _ErrorApplier();
      store.record(
        label: 'op',
        changes: [UndoChange(before: 'B', after: 'A', applier: errorApplier)],
      );
      // Error 不应被吞成 AppFailure——Future 以 error 结束（外抛暴露缺陷）。
      await expectLater(store.undo(), throwsStateError);
      // 外抛后 _executing 必须已复位：追加 record + undo 成功，证明 store 可
      // 继续使用（仅栈标志无法区分 _executing 是否卡死——卡死时 record 被
      // 静默忽略、undo 被互斥拒绝，栈断言仍通过）。
      store.record(
        label: 'after-error',
        changes: [UndoChange(before: 'C', after: 'D', applier: _FakeApplier())],
      );
      expect(await store.undo(), isA<AppSuccess<void>>());
      // 失败的 op 栈不动仍留存（undo 栈）；after-error 已成功撤销（redo 栈）。
      expect(store.canUndo, isTrue);
      expect(store.lastUndoLabel, 'op');
      expect(store.canRedo, isTrue);
      expect(store.lastRedoLabel, 'after-error');
    });

    test('applier 在 apply 段抛 Error（validate 通过）：fail-fast 外抛、记录可重试', () async {
      final applyErrorApplier = _ErrorApplier(throwOnValidate: false);
      store.record(
        label: 'op',
        changes: [UndoChange(before: 'B', after: 'A', applier: applyErrorApplier)],
      );
      // validate 通过、apply 抛 Error：apply 段 catch 不得吞（独立代码路径）。
      await expectLater(store.undo(), throwsStateError);
      // 记录仍留在 undo 栈（_restore 的 finally 复位 _executing 后未迁移）。
      expect(store.canUndo, isTrue);
      expect(store.undoDepth, 1);
      expect(store.canRedo, isFalse);
      expect(store.lastUndoLabel, 'op');
      // 外抛后 _executing 必须已复位：追加 record + undo 成功，证明 store 可
      // 继续使用（仅栈标志无法区分 _executing 是否卡死）。
      store.record(
        label: 'after-error',
        changes: [UndoChange(before: 'C', after: 'D', applier: _FakeApplier())],
      );
      expect(await store.undo(), isA<AppSuccess<void>>());
      expect(store.lastUndoLabel, 'op'); // 失败的 op 仍留存
      expect(store.canRedo, isTrue);
      expect(store.lastRedoLabel, 'after-error');
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

    test('maxDepth <= 0 构造被拒（运行时校验，release 同样生效）', () {
      expect(() => UndoStore(maxDepth: 0), throwsArgumentError);
      expect(() => UndoStore(maxDepth: -1), throwsArgumentError);
      // 最小合法边界：maxDepth: 1 必须可用（构造本身即隐含"不抛"校验），
      // 且丢最旧生效。
      final minStore = UndoStore(maxDepth: 1);
      minStore.record(
        label: 'a',
        changes: [UndoChange(before: 'B1', after: 'A1', applier: _FakeApplier())],
      );
      minStore.record(
        label: 'b',
        changes: [UndoChange(before: 'B2', after: 'A2', applier: _FakeApplier())],
      );
      expect(minStore.undoDepth, 1); // 超限丢最旧
      expect(minStore.lastUndoLabel, 'b');
      minStore.dispose();
    });
  });
}
