// Shared rows for the in-player settings panels (build 29, D 组).
//
// One row set for both panels (VOD + live) so the two sheets look and
// behave the same. iOS-native only: switches are [HaoNativeSwitch]
// (CupertinoSwitch / UISwitch, never a Material Switch), cycle rows
// are [CupertinoButton]s and steppers are −/+ [CupertinoButton]s —
// no Material Switch / Slider / ChoiceChip / RadioListTile anywhere
// in these sheets (station rule: new UI is Cupertino/SwiftUI only).
//
// The sheets are dumb: they take current values + callbacks and own
// no Hive keys. The owning page applies each change (same Hive key
// the settings page reads, same session call the player already
// uses) and rebuilds the sheet via the caller's StatefulBuilder —
// the same pattern as LiveRoomToolsSheet.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import 'native_switch.dart';

/// Small section header inside a settings sheet (same styling as
/// the track-sheet section headers).
class PlayerSettingsSectionTitle extends StatelessWidget {
  const PlayerSettingsSectionTitle(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: TextStyle(
          color: theme.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A switch row: same row-tap toggles + title/subtitle styling as
/// [HaoSwitchRow], plus a nullable [onChanged] so a mutually
/// exclusive row can render locked (greyed out, never a dead
/// toggle that pretends to work).
class PlayerSettingsSwitchRow extends StatelessWidget {
  const PlayerSettingsSwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final bool value;

  /// Null = locked: the row is greyed out and taps do nothing.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final locked = onChanged == null;
    return ListTile(
      title: Text(
        title,
        style: TextStyle(
          color: locked ? theme.textSecondary : theme.textPrimary,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: TextStyle(color: theme.textSecondary)),
      trailing: HaoNativeSwitch(
        value: value,
        onChanged: onChanged,
        enabled: onChanged != null,
        activeColor: theme.accent,
        semanticsLabel: title,
      ),
      onTap: locked ? null : () => onChanged!(!value),
    );
  }
}

/// A cycle row: tap advances to the next value (speed, skip mode,
/// subtitle tier, quality …). The current value is shown on the
/// right; a null [onTap] renders the row disabled.
class PlayerSettingsCycleRow extends StatelessWidget {
  const PlayerSettingsCycleRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.valueLabel,
    required this.onTap,
  });

  final String title;
  final String? subtitle;
  final String valueLabel;

  /// Null = disabled: greyed out, taps do nothing.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final disabled = onTap == null;
    return CupertinoButton(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      onPressed: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: disabled
                        ? theme.textSecondary
                        : theme.textPrimary,
                    fontSize: 16,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: theme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Text(
            valueLabel,
            style: TextStyle(
              color: disabled ? theme.textSecondary : theme.accent,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            CupertinoIcons.chevron_right,
            size: 16,
            color: theme.textSecondary,
          ),
        ],
      ),
    );
  }
}

/// A − / + stepper row (subtitle delay, volume boost): deterministic
/// taps instead of a drag slider, so widget tests can drive it
/// exactly and there is no Material Slider in the sheet.
class PlayerSettingsStepperRow extends StatelessWidget {
  const PlayerSettingsStepperRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.valueLabel,
    required this.onDecrement,
    required this.onIncrement,
    this.decrementKey,
    this.incrementKey,
  });

  final String title;
  final String? subtitle;
  final String valueLabel;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;
  final Key? decrementKey;
  final Key? incrementKey;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 16,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: theme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
          CupertinoButton(
            key: decrementKey,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            onPressed: onDecrement,
            child: Icon(
              CupertinoIcons.minus,
              size: 18,
              color: theme.accent,
            ),
          ),
          SizedBox(
            width: 72,
            child: Text(
              valueLabel,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          CupertinoButton(
            key: incrementKey,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            onPressed: onIncrement,
            child: Icon(
              CupertinoIcons.plus,
              size: 18,
              color: theme.accent,
            ),
          ),
        ],
      ),
    );
  }
}
