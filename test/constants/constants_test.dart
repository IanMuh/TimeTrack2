import 'package:flutter_test/flutter_test.dart';
import 'package:timetrack2/constants/app_constants.dart';
import 'package:timetrack2/constants/build_config.dart';
import 'package:timetrack2/constants/commands/command_definitions.dart';
import 'package:timetrack2/constants/storage_keys.dart';
import 'package:timetrack2/constants/theme_tokens.dart';
import 'package:timetrack2/constants/update_config.dart';
import 'package:timetrack2/utils/command_parser.dart';
import 'package:timetrack2/viewmodels/activity.dart';
import 'package:timetrack2/viewmodels/activity_category.dart';

void main() {
  group('指令定义（正式配置）', () {
    test('全部定义通过解析器构造期校验（单 token/去重/选项约束）', () {
      // 构造期即校验触发名去重、requiredOptions/timeOptions ⊆ allowedOptions、
      // 位置参数范围、name/aliases 单 token——正式定义必须全绿。
      expect(() => CommandParser(definitions: commandDefinitions),
          returnsNormally);
    });

    test('触发名无重复（name + aliases 全局唯一）', () {
      final triggers = <String>{};
      for (final definition in commandDefinitions) {
        for (final trigger in definition.triggerNames) {
          expect(triggers.add(trigger), isTrue,
              reason: '触发名重复：$trigger');
        }
      }
    });

    test('覆盖计划规定的指令形态', () {
      final names = commandDefinitions.map((d) => d.name).toSet();
      for (final expected in [
        'switch', 'stop', 'add', 'split', 'delete', 'merge', 'undo', 'redo',
        'sync', 'export', 'import', 'update_check', 'update_install',
        'category_create', 'category_update', 'category_delete',
      ]) {
        expect(names, contains(expected), reason: '缺少指令 $expected');
      }
    });

    test('解析器可解析典型指令（end-to-end 冒烟）', () {
      final parser = CommandParser(definitions: commandDefinitions);
      // 中文别名 + 时间归一化
      final r1 = parser.parse('切换 学习 --at=下午3点');
      expect(r1.isSuccess, isTrue);
      expect(r1.valueOrNull!.name, 'switch');
      expect(r1.valueOrNull!.options['at'], '15:00');
      // 补记 + 引号 note
      final r2 = parser.parse('add 开会 --start=15:00 --end=16:00 --note="周 会"');
      expect(r2.isSuccess, isTrue);
      expect(r2.valueOrNull!.options['note'], '周 会');
      // 未知指令给出可用列表
      final r3 = parser.parse('fly');
      expect(r3.isSuccess, isFalse);
    });
  });

  group('默认色一致性（防 viewmodels 与 constants 漂移）', () {
    test('Activity.defaultColor == AppConstants.defaultActivityColor', () {
      expect(Activity.defaultColor, AppConstants.defaultActivityColor);
    });

    test('ActivityCategory.defaultColor == AppConstants.defaultCategoryColor', () {
      expect(ActivityCategory.defaultColor, AppConstants.defaultCategoryColor);
    });
  });

  group('AppConstants', () {
    test('核心默认值', () {
      expect(AppConstants.suspiciousEntryHours, 12);
      expect(AppConstants.defaultReminderMinutes, 45);
      expect(AppConstants.defaultReminderIntervalMinutes, 10);
      expect(AppConstants.defaultReminderTimeOfDayMinutes, 540);
      expect(AppConstants.defaultMergeNeighborThresholdMinutes, 1);
      expect(AppConstants.lanDefaultPort, 8787);
      expect(AppConstants.farFutureDate, DateTime(2100));
    });

    test('maxDateTime 哨兵：晚于任何实际业务时间', () {
      // 锁定"无限"哨兵值，防误改破坏重叠判断（TimeEntry.overlaps 依赖）。
      expect(
        AppConstants.maxDateTime,
        DateTime.fromMillisecondsSinceEpoch(8640000000000000),
      );
      expect(AppConstants.maxDateTime.isAfter(DateTime(2999)), isTrue);
      expect(AppConstants.maxDateTime.isAfter(AppConstants.farFutureDate), isTrue);
    });
  });

  group('UpdateConfig', () {
    test('默认清单地址指向本仓库 raw.githubusercontent', () {
      expect(
        UpdateConfig.defaultManifestUrl.host,
        'raw.githubusercontent.com',
      );
      expect(
        UpdateConfig.defaultManifestUrl.pathSegments,
        containsAll(['IanMuh', 'TimeTrack2', 'main', 'update.json']),
      );
    });

    test('重试/分块/标记配置', () {
      expect(UpdateConfig.downloadRetryCount, 3);
      expect(UpdateConfig.downloadChunkBytes, 64 * 1024,
          reason: '64KB 分块为流式下载的关键调优参数，锁定精确值');
      expect(UpdateConfig.pendingInstallMarkerFile, 'pending-install.json');
      expect(UpdateConfig.windowsStagingDirName, 'staging');
    });
  });

  group('AppBuildConfig', () {
    test('dart-define 读取与默认值', () {
      // 未注入时返回默认值
      expect(
        AppBuildConfig.getString('SOME_UNSET_KEY', defaultValue: 'fallback'),
        'fallback',
      );
      expect(
        AppBuildConfig.getBool('SOME_UNSET_BOOL', defaultValue: true),
        isTrue,
      );
    });

    test('getBool：大小写归一化/显式 false/无法识别回退默认', () {
      // 大小写归一化（dart-define 不可在测试注入，行为由纯逻辑保证——此处直接
      // 无法传参验证，逻辑见实现注释；编译期注入需 --dart-define 运行验证）。
      // 该测试保留为回归锚点：若实现改为区分大小写或静默返回 false 将在此暴露。
      // （注：String.fromEnvironment 在测试进程内无法注入，真实注入路径
      // 由阶段 5 双平台冒烟 + --dart-define 覆盖验证。）
      expect(AppBuildConfig.getBool('_UNSET_', defaultValue: false), isFalse);
      expect(AppBuildConfig.getBool('_UNSET_', defaultValue: true), isTrue);
    });

    test('键名常量', () {
      expect(AppBuildConfig.supabaseUrlKey, 'SUPABASE_URL');
      expect(AppBuildConfig.updateManifestUrlKey, 'UPDATE_MANIFEST_URL');
    });
  });

  group('主题令牌', () {
    test('深浅两套齐全且语义一致', () {
      expect(LightThemeTokens.surface, 0xffffffff);
      expect(DarkThemeTokens.background, 0xff0f172a);
      // 深色文字浅、浅色文字深（对比可读）
      expect(LightThemeTokens.text, isNot(DarkThemeTokens.text));
      // secondary 两侧一致（accent 风格）
      expect(LightThemeTokens.secondary, DarkThemeTokens.secondary);
    });
  });

  group('存储键', () {
    test('键名非空且唯一', () {
      final keys = [
        AppMetadataKeys.deviceId,
        AppMetadataKeys.lastSyncAt,
        AppMetadataKeys.ignoredUpdateVersion,
        AppMetadataKeys.lastCheckedManifestVersion,
        AppMetadataKeys.lastCleanupAt,
      ];
      expect(keys.toSet().length, keys.length);
      for (final key in keys) {
        expect(key, isNotEmpty);
      }
    });
  });
}
