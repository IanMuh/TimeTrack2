import 'package:flutter/material.dart' show Color;
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
      // 断言毫秒值（不绑定 isUtc/本地时区构造方式，避免实现变更误报）。
      expect(AppConstants.maxDateTime.millisecondsSinceEpoch, 8640000000000000);
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

    test('resolveManifestUrl：合法/非法/相对/scheme-only/无 host（纯函数单测）', () {
      // 合法 http/https
      expect(
        UpdateConfig.resolveManifestUrl('https://example.com/update.json')!.host,
        'example.com',
      );
      expect(
        UpdateConfig.resolveManifestUrl('http://example.com/x')!.scheme,
        'http',
      );
      // 非法：相对 URI（tryParse 返回非 null 但非绝对）
      expect(UpdateConfig.resolveManifestUrl('foobar'), isNull);
      expect(UpdateConfig.resolveManifestUrl('localhost:8080/update.json'),
          isNull);
      // 非法：scheme-only / 无 host
      expect(UpdateConfig.resolveManifestUrl('https:'), isNull);
      expect(UpdateConfig.resolveManifestUrl('https://'), isNull);
      // 非法：非 http/https scheme
      expect(UpdateConfig.resolveManifestUrl('ftp://example.com/x'), isNull);
      // 非法：空/空白
      expect(UpdateConfig.resolveManifestUrl(''), isNull);
      expect(UpdateConfig.resolveManifestUrl('   '), isNull);
    });
  });

  group('AppBuildConfig', () {
    test('dart-define 读取与默认值', () {
      expect(
        AppBuildConfig.getString('SOME_UNSET_KEY', defaultValue: 'fallback'),
        'fallback',
      );
      expect(AppBuildConfig.getBool('SOME_UNSET_BOOL', defaultValue: true),
          isTrue);
    });

    test('parseBool：大小写归一化/显式 true·false/无法识别回退默认（纯函数单测）', () {
      // 真值（忽略大小写与首尾空白）
      expect(AppBuildConfig.parseBool('true', defaultValue: false), isTrue);
      expect(AppBuildConfig.parseBool('TRUE', defaultValue: false), isTrue);
      expect(AppBuildConfig.parseBool(' 1 ', defaultValue: false), isTrue);
      expect(AppBuildConfig.parseBool('yes', defaultValue: false), isTrue);
      // 假值
      expect(AppBuildConfig.parseBool('false', defaultValue: true), isFalse);
      expect(AppBuildConfig.parseBool('False', defaultValue: true), isFalse);
      expect(AppBuildConfig.parseBool('0', defaultValue: true), isFalse);
      expect(AppBuildConfig.parseBool('no', defaultValue: true), isFalse);
      // 未注入（空/纯空白）→ 默认值
      expect(AppBuildConfig.parseBool('', defaultValue: true), isTrue);
      expect(AppBuildConfig.parseBool('   ', defaultValue: false), isFalse);
      // 无法识别的非空值 → 回退默认（不静默反转为 false）
      expect(AppBuildConfig.parseBool('banana', defaultValue: true), isTrue);
      expect(AppBuildConfig.parseBool('1.0', defaultValue: true), isTrue);
      expect(AppBuildConfig.parseBool('是', defaultValue: false), isFalse);
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

    test('完整令牌集：关键精确值 + 深色 outlineVariant 有意更亮', () {
      // 浅色套关键值
      expect(LightThemeTokens.background, 0xfff8fafc);
      expect(LightThemeTokens.surfaceMuted, 0xfff1f5f9);
      expect(LightThemeTokens.outline, 0xffcbd5e1);
      expect(LightThemeTokens.outlineVariant, 0xffe2e8f0);
      expect(LightThemeTokens.mutedText, 0xff64748b);
      // 深色套关键值
      expect(DarkThemeTokens.outline, 0xff334155);
      expect(DarkThemeTokens.outlineVariant, 0xff475569);
      expect(DarkThemeTokens.mutedText, 0xffcbd5e1);
      // outlineVariant 感知亮度更高（用 computeLuminance 而非 ARGB 整数比较——
      // 整数比较按 R/G/B 字节字典序，不代表感知亮度）
      expect(
        Color(DarkThemeTokens.outlineVariant).computeLuminance(),
        greaterThan(Color(DarkThemeTokens.outline).computeLuminance()),
      );
      expect(
        Color(LightThemeTokens.outlineVariant).computeLuminance(),
        greaterThan(Color(LightThemeTokens.outline).computeLuminance()),
      );
    });
  });

  group('存储键', () {
    test('键名非空且唯一（遍历 AppMetadataKeys.all）', () {
      expect(AppMetadataKeys.all.toSet().length, AppMetadataKeys.all.length);
      for (final key in AppMetadataKeys.all) {
        expect(key, isNotEmpty);
        expect(key.trim(), key, reason: '键名不应含首尾空白');
      }
      // 显式锚点：all 必须包含全部已知键（新增键常量忘同步列表时暴露）
      expect(AppMetadataKeys.all, containsAll([
        AppMetadataKeys.deviceId,
        AppMetadataKeys.lastSyncAt,
        AppMetadataKeys.lastSyncError,
        AppMetadataKeys.lastSyncTarget,
        AppMetadataKeys.ignoredUpdateVersion,
        AppMetadataKeys.lastCheckedManifestVersion,
        AppMetadataKeys.lastCleanupAt,
      ]));
    });
  });
}
