// Emby spec display + filtering (1.1.6, browse A3 §3).
//
// Emby ONLY — CMS has no resolution / bitrate / size signal at all
// (hard block H1: `parseCmsVideoItem` reads 9 fields, none of them a
// spec; the 1080p ceiling forbids labelling any CMS row 4K). CMS rows
// never reach this file: the version sheet hides them under a spec
// filter with an honest empty state instead of inventing a badge.
//
// - `formatEmbyBytes` / `formatEmbyBitrate`: display strings, '' when
//   the server reported nothing (U3-1: Size/BitRate presence on chen's
//   server is still unverified — no signal = no text, never a guess).
// - `EmbySpecFilter`: the version-sheet chips. 4K/DV/HDR match ONLY
//   against parsed facts; a missing field never matches.
// - HDR needs the video range string: `EmbyStreamFacts` does not
//   carry it yet (the HDR group is adding `VideoRange` to that class
//   in this merge — this file takes it as a parameter so it never
//   touches their field). Until then callers pass null and HDR simply
//   never matches, which is the honest answer.
// - `EmbySpecLine`: the card row (badges + size + bitrate +
//   container/codec). Theme variables only; no purple, no red — a
//   spec badge is not a "really meaningful" red.

import 'package:flutter/material.dart';

import '../../core/theme/glass.dart';
import '../../core/theme/hao_themes.dart';
import '../../services/video/emby_models.dart';

/// Bytes → "2.0 GB" / "850 MB" / "900 KB". '' when unknown.
String formatEmbyBytes(int? size) {
  if (size == null || size <= 0) return '';
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (size >= gb) return '${(size / gb).toStringAsFixed(1)} GB';
  if (size >= mb) return '${(size / mb).toStringAsFixed(0)} MB';
  return '${(size / 1024).toStringAsFixed(0)} KB';
}

/// Bits/second → "25.0 Mbps". '' when unknown.
String formatEmbyBitrate(int? bitRate) {
  if (bitRate == null || bitRate <= 0) return '';
  return '${(bitRate / 1000000).toStringAsFixed(1)} Mbps';
}

/// Version-sheet spec filter. Labels are the chip texts.
enum EmbySpecFilter {
  all,
  fourK,
  dolbyVision,
  hdr;

  String get label => switch (this) {
        EmbySpecFilter.all => '全部',
        EmbySpecFilter.fourK => '4K',
        EmbySpecFilter.dolbyVision => '杜比视界',
        EmbySpecFilter.hdr => 'HDR',
      };
}

/// Whether an Emby file passes [filter]. CMS rows never call this —
///
/// the sheet hides them outright under any spec filter (see
/// `showVideoVersionsSheet`).
bool embySpecMatchesFilter(
  EmbyStreamFacts facts,
  EmbySpecFilter filter, {
  String? videoRange,
}) {
  switch (filter) {
    case EmbySpecFilter.all:
      return true;
    case EmbySpecFilter.fourK:
      return (facts.width ?? 0) >= 3840 || (facts.height ?? 0) >= 2160;
    case EmbySpecFilter.dolbyVision:
      return facts.dolbyVision;
    case EmbySpecFilter.hdr:
      // VideoRangeType values beyond DolbyVision are unverified
      // (U3-2: HDR10 / HLG / SDR spellings need a real server).
      // Match only on an explicit HDR/HLG range string; Dolby Vision
      // alone does NOT count as HDR here — its base layer may be
      // HDR10, but claiming it without the range signal is a guess.
      final r = (videoRange ?? '').toLowerCase();
      return r.contains('hdr') || r.contains('hlg');
  }
}

/// Spec badge labels in display order. Empty when the facts say
/// nothing — no badge, never a guess.
List<String> embySpecLabels(
  EmbyStreamFacts facts, {
  String? videoRange,
}) {
  return [
    if (facts.dolbyVision) 'DV',
    if (embySpecMatchesFilter(facts, EmbySpecFilter.fourK)) '4K',
    if (embySpecMatchesFilter(
      facts,
      EmbySpecFilter.hdr,
      videoRange: videoRange,
    ))
      'HDR',
  ];
}

/// One Emby file's spec line: badges + size + bitrate + container /
/// codec. Renders nothing when the facts say nothing. Design values
/// copied from the genre chips / `EmbySpecBadges` (GlassCard radius
/// 999, horizontal 10 / vertical 5): specs read as specs, not genres.
class EmbySpecLine extends StatelessWidget {
  const EmbySpecLine({
    super.key,
    required this.facts,
    this.videoRange,
  });

  final EmbyStreamFacts facts;

  /// Raw video-range string when the caller has it (HDR group's
  /// `VideoRange` field once it lands). Null = HDR never matches.
  final String? videoRange;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final labels = embySpecLabels(facts, videoRange: videoRange);
    final size = formatEmbyBytes(facts.size);
    final bitrate = formatEmbyBitrate(facts.bitRate);
    final container = (facts.container ?? '').toUpperCase();
    final vcodec = (facts.videoCodec ?? '').toUpperCase();
    final acodec = (facts.audioCodec ?? '').toUpperCase();
    final codecParts = [
      if (container.isNotEmpty) container,
      if (vcodec.isNotEmpty) vcodec,
      if (acodec.isNotEmpty) acodec,
    ].join(' · ');
    final metaParts = [
      if (size.isNotEmpty) size,
      if (bitrate.isNotEmpty) bitrate,
      if (codecParts.isNotEmpty) codecParts,
    ].join(' · ');
    if (labels.isEmpty && metaParts.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final label in labels)
          GlassCard(
            radius: 999,
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 5,
            ),
            shadow: GlassShadow.none,
            child: Text(
              label,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        if (metaParts.isNotEmpty)
          Text(
            metaParts,
            style: TextStyle(
              color: theme.textSecondary,
              fontSize: 13,
            ),
          ),
      ],
    );
  }
}
