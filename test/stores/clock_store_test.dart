import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/stores/clock_store.dart';

void main() {
  group('ClockStore', () {
    test('按 interval 周期通知（fake_async 确定性推进）', () {
      fakeAsync((async) {
        var ticks = 0;
        final clock = ClockStore(interval: const Duration(seconds: 1));
        clock.addListener(() => ticks++);
        async.elapse(const Duration(seconds: 3));
        expect(ticks, 3);
        async.elapse(const Duration(seconds: 2));
        expect(ticks, 5);
        clock.dispose();
      });
    });

    test('now() 取自注入源（绝对时间，不随 tick 累计漂移）', () {
      var t = DateTime(2026, 8, 14, 10, 0, 0);
      // 本用例不测定时器，显式 autoStart:false 避免在真实异步区域创建周期
      // Timer（泄漏风险 + 干扰同进程其他测试）。
      final clock = ClockStore(now: () => t, autoStart: false);
      expect(clock.now(), t);
      // 未经过任何 tick，now() 也取到注入源的最新值（绝对语义，
      // 跨日滚转/边界计算依赖精确当前时刻而非 tick 累计）。
      t = DateTime(2026, 8, 14, 10, 0, 30);
      expect(clock.now(), t);
      clock.dispose();
    });

    test('start 幂等；stop 后不再通知；stop 后可重新 start 恢复通知', () {
      fakeAsync((async) {
        var ticks = 0;
        final clock = ClockStore(
          interval: const Duration(seconds: 1),
          autoStart: false,
        );
        expect(clock.isRunning, isFalse);
        clock.addListener(() => ticks++);
        clock.start();
        clock.start(); // 幂等：不重复启动
        expect(clock.isRunning, isTrue);
        async.elapse(const Duration(seconds: 2));
        expect(ticks, 2);
        clock.stop();
        expect(clock.isRunning, isFalse);
        async.elapse(const Duration(seconds: 3));
        expect(ticks, 2); // 停止后不再通知

        clock.start(); // stop 后可重建 Timer 恢复通知
        expect(clock.isRunning, isTrue);
        async.elapse(const Duration(seconds: 1));
        expect(ticks, 3);
        clock.dispose();
      });
    });

    test('dispose 取消 Timer；运行中 dispose 后不再通知', () {
      fakeAsync((async) {
        var ticks = 0;
        final clock = ClockStore(interval: const Duration(seconds: 1));
        clock.addListener(() => ticks++);
        async.elapse(const Duration(seconds: 2));
        expect(ticks, 2);
        clock.dispose();
        expect(clock.isRunning, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(ticks, 2); // 运行中 dispose：Timer 已取消，不再通知
      });
    });

    test('dispose 后 start/stop 无效（不重建 Timer）', () {
      fakeAsync((async) {
        var ticks = 0;
        final clock = ClockStore(interval: const Duration(seconds: 1));
        clock.addListener(() => ticks++);
        clock.dispose();
        clock.start(); // dispose 后 start 必须无效
        expect(clock.isRunning, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(ticks, 0);
      });
    });

    test('interval 为零/负抛 ArgumentError（构造期显式校验）', () {
      expect(
        () => ClockStore(interval: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => ClockStore(interval: const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });
  });
}
