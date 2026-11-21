// HaoSearchField — the app's one search field (N-15).
//
// iOS search-bar behaviour, in theme variables (all 4 themes x
// light/dark):
// - Rounded grey field (theme surface) + search icon.
// - Placeholder CENTRED (icon + hint) while idle; on focus it moves
//   left and the hint left-aligns — the iOS activation behaviour.
// - A × clear button appears when there is text; a text 取消 button
//   slides in on the right while focused. Tapping 取消 clears the
//   text, notifies onChanged('') and dismisses the keyboard (callers
//   pass [onCancel] to also reset their own search state).
// - [trailing] is an optional widget after the field (the song
//   search page's loading spinner).

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/theme/hao_themes.dart';

class HaoSearchField extends StatefulWidget {
  const HaoSearchField({
    super.key,
    this.controller,
    this.focusNode,
    this.hintText = '搜索',
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.onCancel,
    this.onClear,
    this.trailing,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String hintText;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Extra reset work on 取消 (e.g. clear the caller's results).
  /// The field itself always clears the text + unfocuses.
  final VoidCallback? onCancel;

  /// Extra reset work on × (e.g. clear the caller's results). The
  /// field itself always clears the text first.
  final VoidCallback? onClear;

  final Widget? trailing;

  @override
  State<HaoSearchField> createState() => _HaoSearchFieldState();
}

class _HaoSearchFieldState extends State<HaoSearchField> {
  late final TextEditingController _internalController;
  late final FocusNode _internalFocusNode;

  TextEditingController get _controller =>
      widget.controller ?? _internalController;
  FocusNode get _focusNode => widget.focusNode ?? _internalFocusNode;

  @override
  void initState() {
    super.initState();
    _internalController = TextEditingController();
    _internalFocusNode = FocusNode();
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _focusNode.removeListener(_onFocusChanged);
    _internalController.dispose();
    _internalFocusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});
  void _onFocusChanged() => setState(() {});

  void _handleCancel() {
    _controller.clear();
    widget.onChanged?.call('');
    widget.onCancel?.call();
    _focusNode.unfocus();
  }

  void _handleClear() {
    _controller.clear();
    widget.onChanged?.call('');
    widget.onClear?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final focused = _focusNode.hasFocus;
    final text = _controller.text;
    // Idle + empty: the placeholder sits centred (iOS); once the
    // field is active or has text it left-aligns with the icon.
    final showCentredPlaceholder = !focused && text.isEmpty;
    final trailing = widget.trailing;
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: theme.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Row(
                  children: [
                    const SizedBox(width: 10),
                    // Hidden while the centred placeholder overlay is
                    // up, or the field would show two search icons.
                    if (!showCentredPlaceholder) ...[
                      Icon(
                        CupertinoIcons.search,
                        size: 16,
                        color: theme.textMuted,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        autofocus: widget.autofocus,
                        textInputAction: TextInputAction.search,
                        onChanged: widget.onChanged,
                        onSubmitted: widget.onSubmitted,
                        style: TextStyle(
                          color: theme.textPrimary,
                          fontSize: 17,
                        ),
                        decoration: InputDecoration(
                          hintText: showCentredPlaceholder
                              ? ''
                              : widget.hintText,
                          hintStyle: TextStyle(
                            color: theme.textMuted,
                            fontSize: 17,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                    if (text.isNotEmpty)
                      GestureDetector(
                        onTap: _handleClear,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(
                            CupertinoIcons.clear_circled_solid,
                            size: 18,
                            color: theme.textMuted,
                          ),
                        ),
                      )
                    else
                      const SizedBox(width: 10),
                  ],
                ),
                if (showCentredPlaceholder)
                  IgnorePointer(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          CupertinoIcons.search,
                          size: 16,
                          color: theme.textMuted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          widget.hintText,
                          style: TextStyle(
                            color: theme.textMuted,
                            fontSize: 17,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (focused) ...[
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _handleCancel,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 4,
                vertical: 10,
              ),
              child: Text(
                '取消',
                style: TextStyle(color: theme.accent, fontSize: 17),
              ),
            ),
          ),
        ],
        if (trailing != null) ...[
          const SizedBox(width: 6),
          trailing,
        ],
      ],
    );
  }
}
