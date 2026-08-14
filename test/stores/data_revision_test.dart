import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/stores/data_revision.dart';

void main() {
  group('DataRevision', () {
    test('初始为 0；bump 单调递增', () {
      final revision = DataRevision();
      expect(revision.value, 0);
      revision.bump();
      expect(revision.value, 1);
      revision.bump();
      revision.bump();
      expect(revision.value, 3);
      revision.dispose();
    });

    test('bump 触发监听；ValueNotifier == 语义不重复通知同值', () {
      final revision = DataRevision();
      var notified = 0;
      revision.addListener(() => notified++);
      revision.bump(); // 0 → 1
      expect(notified, 1);
      // 手动置为同值：ValueNotifier 按 == 判定，不重复通知。
      revision.value = revision.value;
      expect(notified, 1);
      revision.bump(); // 1 → 2
      expect(notified, 2);
      revision.dispose();
    });
  });
}
