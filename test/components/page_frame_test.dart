import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/components/page_frame.dart';
import 'package:timetrack2/constants/layout.dart';

void main() {
  test('布局令牌按方案锁定（断点/内容宽）', () {
    expect(AppBreakpoints.compact, 600);
    expect(AppBreakpoints.expanded, 840);
    expect(AppBreakpoints.wide, 1280);
    expect(AppContentWidth.timer, 1440);
    expect(AppContentWidth.today, 1120);
    expect(AppContentWidth.stats, 1440);
    expect(AppContentWidth.settings, 1280);
    expect(AppContentWidth.form, 760);
  });

  testWidgets('PageFrame 限宽并水平居中', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: PageFrame(
          maxWidth: 1000,
          child: SizedBox.expand(key: ValueKey('content')),
        ),
      ),
    );

    final rect = tester.getRect(find.byKey(const ValueKey('content')));
    expect(rect.width, 1000);
    expect(rect.height, 900);
    expect(rect.left, 300); // (1600 - 1000) / 2
  });

  testWidgets('maxWidth 为 infinity 时不加约束', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: PageFrame(
          maxWidth: double.infinity,
          child: SizedBox.expand(key: ValueKey('content')),
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(const ValueKey('content'))),
      const Size(1200, 800),
    );
  });
}
