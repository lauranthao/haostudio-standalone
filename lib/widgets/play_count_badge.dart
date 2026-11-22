// PlayCountBadge — Kumone 播放量角标的 Flutter 移植。
//
// Kumone 值来源（逐项，照抄；偏离处见下方“移植说明”）：
// - 结构：HStack(spacing: 3)［图标 + 数字］
//   ~/workspace/research/kumone/Sources/Kumone/DesignSystem/Components.swift:147-152
// - 图标：SF Symbol "play.fill"，size 8，weight bold
//   Components.swift:149-150
// - 数字：Formatters.playCount(count)，size 10，weight semibold
//   Components.swift:151-153；缩写规则见 [format]，
//   ~/workspace/research/kumone/Sources/Kumone/Core/Models/Models.swift:486-513
// - 前景：白色 .foregroundStyle(.white) — Components.swift:154
// - 内边距：horizontal 7，vertical 3.5 — Components.swift:155-156
// - 形状：Capsule — Components.swift:157-158
// - 背景（双层）：black.opacity(0.35) + ultraThinMaterial.opacity(0.6)
//   Components.swift:157-158
// - 显示条件：只在 playCount > 0 时出现（Cards.swift:27）；0 不画“0”
//   ~/workspace/research/kumone/Sources/Kumone/DesignSystem/Cards.swift:27-30
// - 位置（Kumone 原意）：封面右上角，距边 6 — Cards.swift:28-30
//   本 App 广场卡片是 ListTile 行（52px 封面），角标最窄约 47px，
//   6px 内嵌会溢出封面左缘，所以落点改为行尾（badge + chevron），
//   见 plaza_page.dart；96px 的详情页封面才放得下原位（兄弟 case，
//   未改，等 chen 定）。
//
// 移植说明（有意偏离 Kumone 的两处，都有证据）：
// 1. 底衬透明度 0.65 而非 Kumone 的 0.35：角标落在行尾的 scaffold
//    背景上，不是封面照片。0.35 的黑衬叠在浅色 scaffold（#F2F2F7）
//    上约等于 #A9A9B0，白字对比度只有 ~2.4:1，看不清；0.65 约等于
//    #59595E，对比度 ~7:1，深色/浅色都可读。库内先例：
//    video_poster_card.dart:102-124 的集数角标同样白字，用的就是
//    Color(0xA6000000)（黑 0.65）。test/play_count_badge_test.dart
//    用 WCAG 对比度断言锁住这一条（白字 vs 最浅底 ≥ 4.5:1）。
// 2. ultraThinMaterial 层 → App 自带的 DarkGlass（glass.dart）：
//    BackdropFilter 磨砂 + 黑衬，正是“浮在任意内容上的白字小 pill”
//    的库内标准件；模糊 sigma 取主题值 HaoTheme.glassBlurSigma，
//    不写死。图标粗细：Flutter 经典 Material 图标没有 weight 轴，
//    Icons.play_arrow 本身已是实心三角，与 play.fill 等价。
// 3. 颜色上没有硬编码的主题色：角标是“盖在内容上的深色衬 + 白字”，
//    深/浅模式靠底衬本身保证可读（与 Kumone 的设计意图一致）；
//    主题变量体现在 blur sigma（HaoTheme.glassBlurSigma）上。
// 4. 中文单位的判断用设备语言（WidgetsBinding.instance
//    .platformDispatcher.locale），与 Kumone 的 Locale.current.
//    language.languageCode（Models.swift:487-489）同源。不能用
//    Localizations.localeOf：本 App 没有接 flutter_localizations、
//    没声明 supportedLocales，MaterialApp 的默认 delegates 只支持
//    英文，localeOf 在 chen 手机上也会解析成 en_US，12.3万会被写
//    成 123.5K。用 binding 的 dispatcher 而不用 PlatformDispatcher
//    .instance：两者在真机上是同一个，测试里只有 binding 的那
//    个能被 localeTestValue 覆盖。

import 'package:flutter/material.dart';

import '../core/theme/glass.dart';
import '../core/theme/hao_themes.dart';

/// Kumone 风格的播放量角标：▶ 12.3万。
///
/// [count] <= 0 时不渲染任何东西（连空 pill 都不画），与 Kumone
/// `if playCount > 0` 的行为一致。
class PlayCountBadge extends StatelessWidget {
  const PlayCountBadge({super.key, required this.count});

  final int count;

  /// Kumone Formatters.playCount（Models.swift:486-513）逐字移植。
  ///
  /// 中文环境：>= 1亿 → "%.1f亿"，>= 1万 → "%.1f万"，其余原样；
  /// 非中文：>= 1B → "%.1fB"，>= 1M → "%.1fM"，>= 10K → "%.1fK"，
  /// 其余原样。阈值与 Kumone 的 switch 区间完全一致。
  static String format(int count, {required bool useChineseUnits}) {
    if (useChineseUnits) {
      if (count >= 100000000) {
        return '${(count / 100000000).toStringAsFixed(1)}亿';
      }
      if (count >= 10000) {
        return '${(count / 10000).toStringAsFixed(1)}万';
      }
      return '$count';
    }
    if (count >= 1000000000) {
      return '${(count / 1000000000).toStringAsFixed(1)}B';
    }
    if (count >= 1000000) {
      return '${(count / 1000000).toStringAsFixed(1)}M';
    }
    if (count >= 10000) {
      return '${(count / 1000).toStringAsFixed(1)}K';
    }
    return '$count';
  }

  @override
  Widget build(BuildContext context) {
    // Kumone Cards.swift:27 — playCount > 0 才显示。
    if (count <= 0) return const SizedBox.shrink();
    final theme = HaoTheme.of(context);
    // Kumone Models.swift:487-489 — 按当前语言是不是中文选单位；
    // 取设备语言（见文件头移植说明 4），不是 app 解析后的 locale。
    final useChineseUnits =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode ==
        'zh';
    return DarkGlass(
      // Capsule：Kumone Components.swift:157-158 的 Capsule 形状。
      radius: 999,
      sigma: theme.glassBlurSigma,
      // 见文件头移植说明 1：0.65，不是 Kumone 的 0.35。
      color: Colors.black.withValues(alpha: 0.65),
      child: Padding(
        // Kumone Components.swift:155-156：horizontal 7，vertical 3.5。
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Kumone Components.swift:149-150：play.fill，size 8。
            Icon(Icons.play_arrow, shadows: HaoTheme.legibilityShadows(context),  size: 8, color: Colors.white),
            // Kumone Components.swift:148：HStack spacing 3。
            const SizedBox(width: 3),
            Text(
              format(count, useChineseUnits: useChineseUnits),
              // Kumone Components.swift:151-153：size 10，semibold，白字。
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
