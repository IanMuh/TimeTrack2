import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/api/platform/windows_foreground_detector.dart';

/// Windows 前台检测器冒烟测试（flutter_tester 进程内真实 FFI——本套件
/// 运行于 Windows 宿主，user32/kernel32 可加载）。
///
/// 断言边界：不依赖具体前台窗口内容（CI/交互环境结果不定），只锁
/// "调用不抛异常 + 返回类型契约"（processName 可空、windowTitle 非空串
/// 或空串）；重复调用稳定性（句柄即用即关无泄漏副作用）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('isSupported 在 Windows 测试宿主为 true', () {
    // 本仓库仅产出 Windows 桌面；非 Windows 平台该检测器不注册。
    expect(WindowsForegroundDetector.isSupported, isTrue);
  });

  test('processName：多次调用不抛异常且为小写文件名或 null', () {
    final detector = WindowsForegroundDetector();
    for (var i = 0; i < 3; i++) {
      final name = detector.processName;
      if (name != null) {
        expect(name, isNotEmpty);
        expect(name, equals(name.toLowerCase()),
            reason: '进程名应小写归一（规则匹配口径）');
        expect(name.contains('\\') || name.contains('/'), isFalse,
            reason: '应为纯文件名而非完整路径');
      }
    }
  });

  test('windowTitle：多次调用返回字符串（可空）', () {
    final detector = WindowsForegroundDetector();
    for (var i = 0; i < 3; i++) {
      // 无前台窗口时契约允许 null；有则必为 String。
      // ignore: unnecessary_type_check
      expect(detector.windowTitle is String?, isTrue);
    }
  });
}
