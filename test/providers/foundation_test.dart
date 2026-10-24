/// 基础 provider（B1）：时钟 tick/当前日、修订号镜像、撤销状态镜像。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/providers/foundation.dart';
import 'package:timetrack2/providers/infrastructure.dart';
import 'package:timetrack2/stores/undo_store.dart';
import 'package:timetrack2/utils/result.dart';

import '../support/provider_harness.dart';

/// 记录调用次数的空恢复契约（undo 状态镜像测试用）。
class _NoopApplier implements UndoApplier {
  int validateCalls = 0;
  int applyCalls = 0;

  @override
  Future<AppResult<void>> validate(Object? expected) async {
    validateCalls += 1;
    return const AppSuccess(null);
  }

  @override
  Future<AppResult<void>> apply(Object? target) async {
    applyCalls += 1;
    return const AppSuccess(null);
  }
}

void main() {
  group('dataRevisionProvider', () {
    test('镜像服务修订号，bump 后递增', () {
      final container = createTestContainer();
      expect(container.read(dataRevisionProvider), 0);

      // 新写路径经 notifier。
      container.read(dataRevisionProvider.notifier).bump();
      expect(container.read(dataRevisionProvider), 1);

      // 存量 store 直接持有的服务实例是同一对象：外部 bump 也会同步。
      container.read(dataRevisionStoreProvider).bump();
      expect(container.read(dataRevisionProvider), 2);
    });
  });

  group('undoStateProvider', () {
    test('记录/撤销后状态快照同步更新', () async {
      final container = createTestContainer();
      expect(container.read(undoStateProvider).canUndo, isFalse);

      final applier = _NoopApplier();
      container.read(undoStoreProvider).record(
        label: '补记',
        changes: [
          UndoChange(before: 'before', after: 'after', applier: applier),
        ],
      );
      var state = container.read(undoStateProvider);
      expect(state.canUndo, isTrue);
      expect(state.canRedo, isFalse);
      expect(state.lastUndoLabel, '补记');

      await container.read(undoStateProvider.notifier).undo();
      state = container.read(undoStateProvider);
      expect(state.canUndo, isFalse);
      expect(state.canRedo, isTrue);
      expect(state.lastRedoLabel, '补记');
      expect(applier.validateCalls, 1);
      expect(applier.applyCalls, 1);
    });

    test('不可撤销时 undo 返回失败且栈不动', () async {
      final container = createTestContainer();
      final result = await container.read(undoStateProvider.notifier).undo();
      expect(result, isA<AppFailure<void>>());
      expect(container.read(undoStateProvider).canUndo, isFalse);
    });
  });

  group('clockTickProvider / currentDayProvider', () {
    testWidgets('tick 推进时刻，跨午夜时当前日只翻一次', (tester) async {
      var now = DateTime(2026, 1, 1, 23, 59, 58);
      final container = ProviderContainer(
        overrides: [
          clockIntervalProvider.overrideWithValue(const Duration(seconds: 1)),
          // 覆盖时钟注入源：tick 读取可变 now（真实 clockStoreProvider 会
          // 读取该 override 并自行注册 dispose）。
          nowProvider.overrideWithValue(() => now),
        ],
      );
      // testWidgets 在用例体结束时就检查 pending timer（早于 tearDown），
      // 必须在体内显式释放容器（取消 ClockStore 的周期 Timer）。
      try {
        expect(
          container.read(clockTickProvider),
          DateTime(2026, 1, 1, 23, 59, 58),
        );
        expect(container.read(currentDayProvider), DateTime(2026, 1, 1));

        now = DateTime(2026, 1, 1, 23, 59, 59);
        await tester.pump(const Duration(seconds: 1));
        expect(container.read(clockTickProvider), now);
        expect(container.read(currentDayProvider), DateTime(2026, 1, 1));

        now = DateTime(2026, 1, 2, 0, 0, 1);
        await tester.pump(const Duration(seconds: 1));
        expect(container.read(currentDayProvider), DateTime(2026, 1, 2));
      } finally {
        container.dispose();
      }
    });
  });
}

