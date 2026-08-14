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
      final clock = ClockStore(now: () => t);
      expect(clock.now(), t);
      // 未经过任何 tick，now() 也取到注入源的最新值（绝对语义，
      // 跨日滚转/边界计算依赖精确当前时刻而非 tick 累计）。
      t = DateTime(2026, 8, 14, 10, 0, 30);
      expect(clock.now(), t);
      clock.dispose();
    });

    test('start 幂等；stop 后不再通知', () {
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
        clock.dispose();
      });
    });

    test('dispose 取消 Timer，之后不再通知', () {
      fakeAsync((async) {
        var ticks = 0;
        final clock = ClockStore(interval: const Duration(seconds: 1));
        clock.addListener(() => ticks++);
        clock.dispose();
        expect(clock.isRunning, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(ticks, 0); // Timer 已取消
      });
    });
  });
}
