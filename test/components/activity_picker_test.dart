import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/components/activity_picker/activity_picker.dart';
import 'package:timetrack2/viewmodels/activity.dart';
import 'package:timetrack2/viewmodels/activity_category.dart';
import 'package:timetrack2/components/app_theme.dart';
import 'package:timetrack2/l10n/app_localizations.dart';

/// 合并选择器测试（假数据 + 假事件，无 store）。
///
/// 数据：8 活动 6 分类（含 4 层深链：工作 / 项目A / 前端 / 组件库）。
Activity _a(String id, String name, {int color = 0xff10b981}) {
  return Activity(
    id: id,
    name: name,
    color: color,
    isFavorite: true,
    updatedAt: DateTime(2026, 1, 1),
  );
}

void main() {
  Widget host(Widget child, {double width = 1280, double height = 900}) {
    return MediaQuery(
      data: MediaQueryData(size: Size(width, height)),
      child: MaterialApp(
        theme: buildTimeTrackTheme(Brightness.light),
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  ActivityPickerModel model() {
    // 分类层级：工作(0) → 项目A(1) → 前端(2) → 组件库(3)；生活(4)。
    final rootA =
        ActivityCategory(id: 'c0', name: '工作', color: 0xff6366f1, updatedAt: DateTime(2026), parentId: null);
    final projA = ActivityCategory(id: 'c1', name: '项目A', color: 0xff8b5cf6, updatedAt: DateTime(2026), parentId: 'c0');
    final front = ActivityCategory(id: 'c2', name: '前端', color: 0xff0ea5e9, updatedAt: DateTime(2026), parentId: 'c1');
    final libs = ActivityCategory(id: 'c3', name: '组件库', color: 0xff14b8a6, updatedAt: DateTime(2026), parentId: 'c2');
    final life = ActivityCategory(id: 'c4', name: '生活', color: 0xfff59e0b, updatedAt: DateTime(2026), parentId: null);
    final categories = [rootA, projA, front, libs, life];
    final activities = [
      _a('a1', '写代码', color: 0xff10b981),
      _a('a2', '设计评审'),
      _a('a3', '休息', color: 0xfff43f5e),
      _a('a4', '撸猫', color: 0xfff59e0b),
    ];
    return ActivityPickerModel(
      activities: activities,
      categories: categories,
      descendantsOf: {
        'c0': {'c1', 'c2', 'c3'},
        'c1': {'c2', 'c3'},
        'c2': {'c3'},
        'c3': {},
        'c4': {},
      },
      childrenByParent: {
        null: [rootA, life],
        'c0': [projA],
        'c1': [front],
        'c2': [libs],
        'c3': const [],
        'c4': const [],
      },
      ancestorChain: {
        'c0': ['工作'],
        'c1': ['工作', '项目A'],
        'c2': ['工作', '项目A', '前端'],
        'c3': ['工作', '项目A', '前端', '组件库'],
        'c4': ['生活'],
      },
      primaryCategoryIdByActivity: {
        'a1': 'c2',
        'a2': 'c1',
        'a3': 'c4',
        'a4': null,
      },
      categoryIdsByActivity: {
        'a1': {'c2'},
        'a2': {'c1'},
        'a3': {'c4'},
        'a4': {},
      },
    );
  }

  testWidgets('新建活动表单提交 → onCreateActivity 收到草稿', (tester) async {
    ActivityDraft? draft;
    final events = ActivityPickerEvents(
      onSelectActivity: (_) {},
      onCreateActivity: (d) async {
        draft = d;
        return true;
      },
    );
    await tester.pumpWidget(host(Builder(
      builder: (context) => FilledButton(
        onPressed: () => showActivityCategoryPickerDialog(
          context,
          model: model(),
          events: events,
        ),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget, reason: '弹窗应打开');
    expect(find.byType(TextField), findsOneWidget, reason: '搜索框在');
    expect(find.text('新建分类'), findsOneWidget, reason: '底部双入口应在');
    await tester.tap(find.text('新建活动'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '冥想');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(draft?.name, '冥想');
  });

  testWidgets('弹窗渲染活动集；选中回调 + 关窗', (tester) async {
    Activity? picked;
    final events = ActivityPickerEvents(onSelectActivity: (a) => picked = a);
    await tester.pumpWidget(host(Builder(
      builder: (context) => FilledButton(
        onPressed: () => showActivityCategoryPickerDialog(
          context,
          model: model(),
          events: events,
        ),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('写代码'), findsOneWidget);
    await tester.tap(find.text('设计评审'));
    await tester.pumpAndSettle();
    expect(picked?.id, 'a2');
    expect(find.text('写代码'), findsNothing, reason: '选择后弹窗应关闭');
  });

  testWidgets('分类树选中过滤活动集；深 4 层节点显示祖先链路径', (tester) async {
    await tester.pumpWidget(host(Builder(
      builder: (context) => FilledButton(
        onPressed: () => showActivityCategoryPickerDialog(
          context,
          model: model(),
          events: ActivityPickerEvents(onSelectActivity: (_) {}),
        ),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 展开 工作 → 项目A → 前端 → 组件库（深 4 层）。
    await tester.tap(find.byIcon(Icons.keyboard_arrow_right_rounded).first);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.keyboard_arrow_right_rounded).first);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.keyboard_arrow_right_rounded).first);
    await tester.pump();
    await tester.pumpAndSettle();
    // 组件库（第 4 层）以祖先链路径呈现（不再第 4 级缩进）。
    expect(find.text('工作 / 项目A / 前端 / 组件库'), findsOneWidget);

    // 选中"前端"→ 右列只剩其子树活动（a1 写代码；设计评审属"项目A"子树不在此层）。
    await tester.tap(find.text('前端'));
    await tester.pump();
    expect(find.text('写代码'), findsOneWidget);
    expect(find.text('撸猫'), findsNothing);
    expect(find.text('设计评审'), findsNothing);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
  });

  testWidgets('跨分类搜索实时过滤活动', (tester) async {
    await tester.pumpWidget(host(Builder(
      builder: (context) => FilledButton(
        onPressed: () => showActivityCategoryPickerDialog(
          context,
          model: model(),
          events: ActivityPickerEvents(onSelectActivity: (_) {}),
        ),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '猫');
    await tester.pump();
    expect(find.text('撸猫'), findsOneWidget);
    expect(find.text('写代码'), findsNothing);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
  });

  testWidgets('递归删除确认 → onDeleteCategory 收到该分类', (tester) async {
    ActivityCategory? deleted;
    final events = ActivityPickerEvents(
      onSelectActivity: (_) {},
      onDeleteCategory: (c) async {
        deleted = c;
        return true;
      },
    );
    await tester.pumpWidget(host(Builder(
      builder: (context) => FilledButton(
        onPressed: () => showActivityCategoryPickerDialog(
          context,
          model: model(),
          events: events,
        ),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // 长按"工作"节点 → 删除菜单。
    await tester.longPress(find.text('工作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();
    expect(deleted?.id, 'c0');
  });

  testWidgets('移动抽屉形态：搜索 + 选中', (tester) async {
    Activity? picked;
    final events = ActivityPickerEvents(onSelectActivity: (a) => picked = a);
    await tester.pumpWidget(host(
      Builder(
        builder: (context) => FilledButton(
          onPressed: () => showActivityCategoryPickerSheet(
            context,
            model: model(),
            events: events,
          ),
          child: const Text('open'),
        ),
      ),
      width: 390,
      height: 844,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('写代码'), findsOneWidget);
    await tester.tap(find.text('休息'));
    await tester.pumpAndSettle();
    expect(picked?.id, 'a3');
  });
}
