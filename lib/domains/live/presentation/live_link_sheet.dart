// Link toolbox sheet — item 9 (build 29, I group).
//
// Paste any platform live link, parse it, jump into the room.
// Short links (v.douyin.com etc.) are resolved over the network
// first; a link that does not parse says so plainly instead of
// opening a wrong room. The sheet never guesses: [onOpenRoom] only
// fires with a parsed platform + room id, and the room page
// resolves the detail fresh on entry (a Kuaishou user id / Douyin
// webRid is resolved by its adapter there).

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/models/live_models.dart';
import '../../../../core/theme/hao_themes.dart';
import '../live_link_parser.dart';
import '../../../widgets/hao_sheet.dart';

/// Show the paste-a-link sheet. [onOpenRoom] receives the parsed
/// room (platform + room id); the caller opens the room page.
Future<void> showLiveLinkSheet({
  required BuildContext context,
  required void Function(LiveRoom room) onOpenRoom,
}) {
  return showHaoSheet<void>(
    context: context,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _LiveLinkSheet(onOpenRoom: onOpenRoom),
    ),
  );
}

class _LiveLinkSheet extends StatefulWidget {
  const _LiveLinkSheet({required this.onOpenRoom});

  final void Function(LiveRoom room) onOpenRoom;

  @override
  State<_LiveLinkSheet> createState() => _LiveLinkSheetState();
}

class _LiveLinkSheetState extends State<_LiveLinkSheet> {
  final _controller = TextEditingController();
  bool _resolving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isNotEmpty) {
      setState(() {
        _controller.text = text;
        _error = null;
      });
    }
  }

  Future<void> _go() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;
    setState(() {
      _resolving = true;
      _error = null;
    });
    final parsed = await parseOrResolveLiveLink(input);
    if (!mounted) return;
    setState(() => _resolving = false);
    if (parsed == null) {
      setState(() {
        _error = '不是有效的直播链接（仅支持 Bilibili / 斗鱼 / 虎牙 / 抖音 / 快手直播间链接）';
      });
      return;
    }
    Navigator.of(context).pop();
    widget.onOpenRoom(
      LiveRoom(roomId: parsed.roomId, platform: parsed.platform),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceSolid,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '粘贴直播链接进房',
            style: TextStyle(
              shadows: HaoTheme.legibilityShadows(context),
              color: theme.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '支持 Bilibili、斗鱼、虎牙、抖音、快手直播间链接（含短链接）',
            style: TextStyle(
              shadows: HaoTheme.legibilityShadows(context),
              color: theme.textMuted,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: InputDecoration(
                    hintText: '粘贴链接，如 https://live.bilibili.com/…',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _go(),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: _paste, child: const Text('粘贴')),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(
                shadows: HaoTheme.legibilityShadows(context),
                color: theme.liveRed,
                fontSize: 13,
              ),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _resolving ? null : _go,
              style: FilledButton.styleFrom(
                backgroundColor: theme.accent,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              child: _resolving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CupertinoActivityIndicator(),
                    )
                  : const Text('进房', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}
