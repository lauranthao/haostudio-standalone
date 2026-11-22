// Emby connect page (build 29, C group) — rebuild of the Emby
// setup form after chen's reference screenshots ("添加 Emby" from
// another app, two screenshots = top + bottom of one page).
//
// Layout follows the reference, top to bottom:
// - App bar: ✕ close left, title 添加/编辑 Emby, paste action right.
// - Emby logo tile + live name + "媒体库、元数据与播放进度".
// - Form group: 名称 / 备注 / 地址 / 端口（默认 8,096) / 路径
//   （可留空，如 /emby) / HTTPS 开关（HTTP 连接） / 用户名 /
//   密码（眼睛显隐）.
// - 播放 group: 备用线路 (manual add, per-line test).
// - 通知提醒 group: 未播放提醒 (关闭 / 3 / 7 / 14 / 30 天）.
// - 高级设置 (collapsible): 数据上报 (default on), STRM 直连
//   (default off), API 密钥 (fallback credential).
// - Bottom big button 连接并保存 — disabled (grey) until the
//   required fields are filled: address + (username OR api key).
//
// What is deliberately NOT on this page:
// - 同步到 Trakt: Trakt needs an OAuth login (a Trakt account
//   authorisation), and the app has no login interface; its sync
//   would also have to be wired in the player (not this group's
//   files). No row, no dead switch — see the C-group report.
// - 未播放提醒 only stores the day threshold (see EmbyReminder):
//   firing a reminder needs a notification channel + an app-start
//   check, neither of which exists in this version.
//
// Auth: username + password is the primary path — POST
// /Users/AuthenticateByName, token + user id stored, the password
// never stored. API key (advanced) is the fallback path, with the
// old probe (System/Info + users). A saved token login is kept
// when the user re-opens the page and leaves the password blank.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/hao_themes.dart';
import '../../services/video/emby_client.dart';
import '../../services/video/emby_models.dart';
import '../../widgets/glass_dialog.dart';
import '../../widgets/hao_toast.dart';
import '../../widgets/native_switch.dart';
import '../../widgets/settings_ui.dart';
import '../../widgets/hao_nav_bar.dart';

/// The Emby brand mark, drawn (no official asset in the repo):
/// Emby green rounded square + white play triangle. The green is
/// the brand colour, not a theme colour.
class EmbyLogo extends StatelessWidget {
  const EmbyLogo({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF52B54B),
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      child: Icon(
        Icons.play_arrow,
        color: Colors.white,
        size: size * 0.55,
        shadows: const [Shadow(color: Colors.black26, blurRadius: 2)],
      ),
    );
  }
}

/// Emby connect page. [initialConfig] is the stored config to edit
/// (null = new server); legacy build-28 configs (baseUrl + apiKey)
/// are split into the form fields on open. [clientFactory] builds
/// the client for a config — tests inject a canned fetcher/mutator
/// through it; production uses the real client. Saving goes through
/// [EmbyConfigStore] and the page pops `true` on success.
class EmbyConnectPage extends StatefulWidget {
  const EmbyConnectPage({super.key, this.initialConfig, this.clientFactory});

  final EmbyServerConfig? initialConfig;

  /// (config) => client. Null = `EmbyClient(config: config)`.
  final EmbyClient Function(EmbyServerConfig config)? clientFactory;

  @override
  State<EmbyConnectPage> createState() => _EmbyConnectPageState();
}

class _EmbyConnectPageState extends State<EmbyConnectPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _noteController;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _pathController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _apiKeyController;

  late bool _useHttps;
  late bool _reportProgress;
  late bool _strmDirect;
  late int _reminderDays;
  late List<String> _fallbackUrls;
  late String _deviceId;

  bool _showPassword = false;
  bool _advancedExpanded = false;
  bool _busy = false;
  bool _httpWarned = false;
  String _status = '';
  bool _statusOk = false;

  /// Main address failed but a fallback line answered: offer a
  /// one-tap switch of the main address to that line.
  String? _swapOffer;

  bool get _hasSavedToken =>
      (widget.initialConfig?.accessToken ?? '').isNotEmpty;

  EmbyClient _clientFor(EmbyServerConfig config) =>
      widget.clientFactory?.call(config) ?? EmbyClient(config: config);

  @override
  void initState() {
    super.initState();
    final initial = widget.initialConfig;
    final address = EmbyServerAddress.parse(initial?.baseUrl ?? '');
    _nameController = TextEditingController(text: initial?.name ?? 'Emby');
    _noteController = TextEditingController(text: initial?.note ?? '');
    _hostController = TextEditingController(text: address.host);
    _portController = TextEditingController(
      text: initial == null ? '' : '${address.port}',
    );
    _pathController = TextEditingController(text: address.path);
    _usernameController =
        TextEditingController(text: initial?.username ?? '');
    _passwordController = TextEditingController();
    _apiKeyController = TextEditingController(text: initial?.apiKey ?? '');
    _useHttps = address.useHttps;
    _reportProgress = initial?.reportProgress ?? true;
    _strmDirect = initial?.strmDirect ?? false;
    _reminderDays = initial?.reminderDays ?? 0;
    _fallbackUrls = List<String>.from(initial?.fallbackUrls ?? const []);
    _deviceId = (initial?.deviceId ?? '').isNotEmpty
        ? initial!.deviceId
        : EmbyServerConfig.newDeviceId();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _noteController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _pathController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  /// Required fields: address + (username OR api key). The
  /// password is not required — an Emby user may have none.
  bool get _canConnect =>
      _hostController.text.trim().isNotEmpty &&
      (_usernameController.text.trim().isNotEmpty ||
          _apiKeyController.text.trim().isNotEmpty);

  int get _port {
    final parsed = int.tryParse(_portController.text.trim());
    if (parsed == null || parsed < 1 || parsed > 65535) return 8096;
    return parsed;
  }

  EmbyServerConfig _draftConfig({
    String? accessToken,
    String? userId,
    String? serverName,
    String? serverVersion,
  }) {
    final prev = widget.initialConfig;
    // Username empty = key mode: the old account token must not
    // survive (otherwise authToken would keep sending the stale
    // token and the key would never be used). Username filled =
    // account mode: keep the previous token/user unless the caller
    // passed fresh ones.
    final username = _usernameController.text.trim();
    final keepAccount = username.isNotEmpty;
    return EmbyServerConfig(
      baseUrl: EmbyServerAddress.compose(
        useHttps: _useHttps,
        host: _hostController.text.trim(),
        port: _port,
        path: _pathController.text.trim(),
      ),
      apiKey: _apiKeyController.text.trim(),
      userId: keepAccount
          ? (userId ?? prev?.userId ?? '')
          : (userId ?? ''),
      enabled: prev?.enabled ?? true,
      movieLibraryId: prev?.movieLibraryId,
      tvLibraryId: prev?.tvLibraryId,
      name: _nameController.text.trim().isEmpty
          ? 'Emby'
          : _nameController.text.trim(),
      note: _noteController.text.trim(),
      username: username,
      accessToken:
          keepAccount ? (accessToken ?? prev?.accessToken ?? '') : '',
      deviceId: _deviceId,
      serverName: serverName ?? prev?.serverName ?? '',
      serverVersion: serverVersion ?? prev?.serverVersion ?? '',
      reportProgress: _reportProgress,
      strmDirect: _strmDirect,
      fallbackUrls: _fallbackUrls,
      reminderDays: _reminderDays,
      lastPlayedAtMs: prev?.lastPlayedAtMs,
    );
  }

  void _setStatus(String text, {bool ok = false}) {
    if (!mounted) return;
    setState(() {
      _status = text;
      _statusOk = ok;
    });
  }

  Future<void> _pasteAddress() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = (data?.text ?? '').trim();
    if (text.isEmpty) {
      HaoToast.show('剪贴板是空的', message: '请先复制服务器地址');
      return;
    }
    // First whitespace-separated token only (a copied message may
    // carry more text around the URL).
    final token = text.split(RegExp(r'\s+')).first;
    final address = EmbyServerAddress.parse(token);
    if (address.host.isEmpty) {
      HaoToast.show('剪贴板里没有服务器地址', message: '请复制服务器域名或 IP');
      return;
    }
    setState(() {
      _useHttps = address.useHttps;
      _hostController.text = address.host;
      _portController.text = '${address.port}';
      _pathController.text = address.path;
    });
  }

  Future<void> _saveAndClose(EmbyServerConfig config) async {
    final saved = await EmbyConfigStore.save(config);
    if (!mounted) return;
    if (!saved) {
      _setStatus('保存失败，请重试');
      return;
    }
    HaoToast.show(
      '已连接',
      message: config.serverName.isNotEmpty
          ? config.serverName
          : config.name,
    );
    Navigator.of(context).pop(true);
  }

  /// Multi-user picker (key mode, probe returned > 1 user).
  /// Returns the picked user id, or null when cancelled.
  Future<String?> _pickUser(List<EmbyUser> users) async {
    return showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('选择用户'),
        message: const Text('这个服务器上有多个用户'),
        actions: [
          for (final user in users)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(ctx).pop(user.id),
              child: Text(user.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
      ),
    );
  }

  Future<void> _pickReminder() async {
    final picked = await showCupertinoModalPopup<int>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('未播放提醒'),
        message: const Text('这么多天没在这里播放时提醒你'),
        actions: [
          for (final days in EmbyReminder.options)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(ctx).pop(days),
              child: Text(EmbyReminder.label(days)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() => _reminderDays = picked);
    }
  }

  Future<void> _openFallbackEditor() async {
    final updated = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute<List<String>>(
        builder: (_) => _EmbyFallbackLinesPage(
          initialLines: _fallbackUrls,
          clientFactory: widget.clientFactory,
        ),
      ),
    );
    if (updated != null && mounted) {
      setState(() => _fallbackUrls = updated);
    }
  }

  Future<void> _connect() async {
    if (_busy || !_canConnect) return;
    final host = _hostController.text.trim();
    if (host.isEmpty) {
      _setStatus('请先填写服务器地址');
      return;
    }
    if (!_useHttps && !_httpWarned) {
      // Plain-http server: warn clearly (requests go in the clear),
      // but do NOT block — a LAN http address is a legal setup.
      final keep = await showGlassConfirmDialog(
        context,
        title: '该地址使用明文 http',
        content:
            'Emby 服务器地址是 http://，请求将以明文传输，同一网络下可能被窃听或篡改。建议改用支持 https 的地址。',
        confirmLabel: '仍要连接',
      );
      if (keep != true || !mounted) return;
      _httpWarned = true;
    }
    setState(() {
      _busy = true;
      _swapOffer = null;
      _status = '正在连接…';
      _statusOk = false;
    });
    try {
      final username = _usernameController.text.trim();
      if (username.isNotEmpty) {
        await _connectWithAccount(username);
      } else {
        await _connectWithKey();
      }
    } catch (_) {
      _setStatus('连接失败，请检查地址和网络');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Password login path. On auth success, a best-effort probe
  /// fills in the server name/version (a failed probe after a
  /// successful login does not block the save — the login already
  /// proved server + credentials).
  Future<void> _connectWithAccount(String username) async {
    final password = _passwordController.text;
    final draft = _draftConfig();
    final client = _clientFor(draft);

    // Re-opening the page with a saved token and a blank password:
    // keep the token, do not re-auth with an empty password.
    if (password.isEmpty &&
        _hasSavedToken &&
        username == (widget.initialConfig?.username ?? '') &&
        (widget.initialConfig?.accessToken ?? '').isNotEmpty) {
      final config = _draftConfig(
        accessToken: widget.initialConfig!.accessToken,
        userId: widget.initialConfig!.userId,
      );
      final probe = await _clientFor(config).probe();
      if (!probe.ok) {
        _setStatus('已保存的登录失效：${probe.errorMessage}，请重新输入密码');
        return;
      }
      await _saveAndClose(
        config.copyWith(
          serverName: probe.serverName,
          serverVersion: probe.version,
        ),
      );
      return;
    }

    final auth = await client.authenticateByName(
      username: username,
      password: password,
    );
    if (!auth.ok) {
      if (auth.errorKind == EmbyErrorKind.unreachable &&
          _fallbackUrls.isNotEmpty) {
        // Main address down: try the fallback lines with the same
        // credentials and offer the first one that answers.
        for (final line in _fallbackUrls) {
          final retry = await client.authenticateByName(
            username: username,
            password: password,
            baseUrl: line,
            timeout: const Duration(seconds: 5),
          );
          if (retry.ok) {
            if (!mounted) return;
            setState(() => _swapOffer = line);
            _setStatus('主线路连不上，备用线路可连通');
            return;
          }
        }
      }
      _setStatus(auth.errorMessage);
      return;
    }
    final config = _draftConfig(
      accessToken: auth.accessToken,
      userId: auth.userId,
    );
    final probe = await _clientFor(config).probe();
    await _saveAndClose(
      config.copyWith(
        serverName: probe.ok ? probe.serverName : '',
        serverVersion: probe.ok ? probe.version : '',
      ),
    );
  }

  /// API-key path (advanced): the old probe, single user auto-taken,
  /// multi-user picked. A probe that only answers on a fallback
  /// line offers the switch instead of failing outright.
  Future<void> _connectWithKey() async {
    final draft = _draftConfig();
    final probe = await _clientFor(draft).probe();
    if (!probe.ok) {
      if (probe.workingBaseUrl.isNotEmpty &&
          probe.workingBaseUrl != draft.baseUrl) {
        if (!mounted) return;
        setState(() => _swapOffer = probe.workingBaseUrl);
        _setStatus('主线路连不上，备用线路可连通');
        return;
      }
      _setStatus(probe.errorMessage);
      return;
    }
    var userId = '';
    if (probe.users.length == 1) {
      userId = probe.users.first.id;
    } else if (probe.users.length > 1) {
      final picked = await _pickUser(probe.users);
      if (picked == null) {
        _setStatus('请选择一个用户');
        return;
      }
      userId = picked;
    }
    await _saveAndClose(
      draft.copyWith(
        userId: userId,
        serverName: probe.serverName,
        serverVersion: probe.version,
      ),
    );
  }

  /// Apply the offered fallback line as the main address and retry.
  void _applySwapOffer() {
    final line = _swapOffer;
    if (line == null) return;
    final address = EmbyServerAddress.parse(line);
    if (address.host.isEmpty) return;
    setState(() {
      _useHttps = address.useHttps;
      _hostController.text = address.host;
      _portController.text = '${address.port}';
      _pathController.text = address.path;
      _swapOffer = null;
    });
    _connect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.ofOrDefault(context);
    final isEdit = (widget.initialConfig?.isConfigured ?? false);
    return Scaffold(
      appBar: HaoNavBar(
        title: isEdit ? '编辑 Emby' : '添加 Emby',
        leading: HaoNavBarButton( onPressed: () => Navigator.of(context).pop(),child: Icon(
            Icons.close,
            shadows: HaoTheme.legibilityShadows(context),
          )),
        actions: [HaoNavBarButton( onPressed: _pasteAddress,child: Icon(
              Icons.content_paste,
              shadows: HaoTheme.legibilityShadows(context),
            ))],
      ),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _buildHeader(theme),
          const SizedBox(height: 20),
          SettingsGroup(
            children: [
              _textRow(theme, label: '名称', controller: _nameController,
                  hint: 'Emby', fieldKey: const Key('emby_name')),
              _textRow(theme, label: '备注', controller: _noteController,
                  hint: '到期时间、账号归属…', fieldKey: const Key('emby_note')),
              _textRow(
                theme,
                label: '地址',
                controller: _hostController,
                hint: '服务器域名或 IP',
                keyboardType: TextInputType.url,
                fieldKey: const Key('emby_host'),
              ),
              _textRow(
                theme,
                label: '端口',
                controller: _portController,
                hint: '默认 8,096',
                keyboardType: TextInputType.number,
                fieldKey: const Key('emby_port'),
              ),
              _textRow(theme, label: '路径', controller: _pathController,
                  hint: '可留空，如 /emby', fieldKey: const Key('emby_path')),
              HaoSwitchRow(
                title: 'HTTPS',
                subtitle: _useHttps ? 'HTTPS 连接' : 'HTTP 连接',
                value: _useHttps,
                onChanged: (v) => setState(() => _useHttps = v),
              ),
              _textRow(
                theme,
                label: '用户名',
                controller: _usernameController,
                hint: '用户名',
                fieldKey: const Key('emby_username'),
              ),
              _passwordRow(theme),
            ],
          ),
          const SizedBox(height: 8),
          const HaoHint('密码仅用于本次登录换取令牌，不会保存在设备上。没有账号时，可在高级设置里用 API 密钥连接。'),
          const SizedBox(height: 20),
          const HaoSectionTitle('播放'),
          SettingsGroup(
            children: [
              ListTile(
                title: Text(
                  '备用线路',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  _fallbackUrls.isEmpty
                      ? '手动添加备用地址'
                      : '${_fallbackUrls.length} 条备用地址',
                  style: TextStyle(color: theme.textSecondary),
                ),
                trailing: const HaoChevron(),
                onTap: _openFallbackEditor,
              ),
            ],
          ),
          const SizedBox(height: 20),
          const HaoSectionTitle('通知提醒'),
          SettingsGroup(
            children: [
              ListTile(
                title: Text(
                  '未播放提醒',
                  style: TextStyle(color: theme.textPrimary),
                ),
                subtitle: Text(
                  '这么多天没在这里播放时提醒你',
                  style: TextStyle(color: theme.textSecondary),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      EmbyReminder.label(_reminderDays),
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.unfold_more,
                      color: theme.textMuted,
                      size: 20,
                      shadows: HaoTheme.legibilityShadows(context),
                    ),
                  ],
                ),
                onTap: _pickReminder,
              ),
            ],
          ),
          const SizedBox(height: 20),
          _buildAdvanced(theme),
          const SizedBox(height: 24),
          if (_status.isNotEmpty) ...[
            Text(
              _status,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _statusOk ? theme.accent : theme.liveRed,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (_swapOffer != null) ...[
            Center(
              child: TextButton(
                onPressed: _busy ? null : _applySwapOffer,
                child: const Text('改用这条线路'),
              ),
            ),
            const SizedBox(height: 8),
          ],
          FilledButton(
            onPressed: (_canConnect && !_busy) ? _connect : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              textStyle: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: Text(_busy ? '连接中…' : '连接并保存'),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(HaoTheme theme) {
    return Row(
      children: [
        const EmbyLogo(size: 64),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _nameController,
                builder: (_, value, child) => Text(
                  value.text.trim().isEmpty ? 'Emby' : value.text.trim(),
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '媒体库、元数据与播放进度',
                style: TextStyle(color: theme.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAdvanced(HaoTheme theme) {
    return SettingsGroup(
      children: [
        ListTile(
          title: Text(
            '高级设置',
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          trailing: Icon(
            _advancedExpanded
                ? Icons.keyboard_arrow_up
                : Icons.keyboard_arrow_down,
            color: theme.textMuted,
            shadows: HaoTheme.legibilityShadows(context),
          ),
          onTap: () =>
              setState(() => _advancedExpanded = !_advancedExpanded),
        ),
        if (_advancedExpanded) ...[
          HaoSwitchRow(
            title: '数据上报',
            subtitle: '向服务器同步播放进度，用于继续观看和已看标记',
            value: _reportProgress,
            onChanged: (v) => setState(() => _reportProgress = v),
          ),
          HaoSwitchRow(
            title: 'STRM 直连',
            subtitle: '开启时直接播放 STRM 目标地址；关闭时由服务器提供播放地址，适用于绝大多数服务器',
            value: _strmDirect,
            onChanged: (v) => setState(() => _strmDirect = v),
          ),
          _textRow(
            theme,
            label: 'API 密钥',
            controller: _apiKeyController,
            hint: '无账号时用密钥连接',
            obscure: true,
            fieldKey: const Key('emby_api_key'),
          ),
        ],
      ],
    );
  }

  Widget _textRow(
    HaoTheme theme, {
    required String label,
    required TextEditingController controller,
    String? hint,
    TextInputType? keyboardType,
    bool obscure = false,
    Key? fieldKey,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: TextStyle(color: theme.textPrimary, fontSize: 16),
            ),
          ),
          Expanded(
            child: TextField(
              key: fieldKey,
              controller: controller,
              textAlign: TextAlign.right,
              obscureText: obscure,
              keyboardType: keyboardType,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration.collapsed(
                hintText: hint,
                hintStyle: TextStyle(color: theme.textMuted, fontSize: 16),
              ),
              style: TextStyle(color: theme.textPrimary, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _passwordRow(HaoTheme theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              '密码',
              style: TextStyle(color: theme.textPrimary, fontSize: 16),
            ),
          ),
          Expanded(
            child: TextField(
              key: const Key('emby_password'),
              controller: _passwordController,
              textAlign: TextAlign.right,
              obscureText: !_showPassword,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration.collapsed(
                hintText: _hasSavedToken ? '已登录，留空保持不变' : '密码',
                hintStyle: TextStyle(color: theme.textMuted, fontSize: 16),
              ),
              style: TextStyle(color: theme.textPrimary, fontSize: 16),
            ),
          ),
          IconButton(
            icon: Icon(
              _showPassword ? Icons.visibility : Icons.visibility_off,
              color: theme.textMuted,
              shadows: HaoTheme.legibilityShadows(context),
            ),
            tooltip: _showPassword ? '隐藏密码' : '显示密码',
            onPressed: () => setState(() => _showPassword = !_showPassword),
          ),
        ],
      ),
    );
  }
}

/// 备用线路 editor: manual add / delete / per-line test.
///
/// A line is a full server base URL (pasted or typed). Test pings
/// the line's public info endpoint — no credential needed — and
/// reports whether that address is an Emby server. Popping with
/// the updated list (back button included) returns it to the
/// connect page; nothing is saved to Hive here.
class _EmbyFallbackLinesPage extends StatefulWidget {
  const _EmbyFallbackLinesPage({
    required this.initialLines,
    this.clientFactory,
  });

  final List<String> initialLines;
  final EmbyClient Function(EmbyServerConfig config)? clientFactory;

  @override
  State<_EmbyFallbackLinesPage> createState() =>
      _EmbyFallbackLinesPageState();
}

class _EmbyFallbackLinesPageState extends State<_EmbyFallbackLinesPage> {
  late List<String> _lines;
  late final TextEditingController _newLineController;

  /// line -> last test outcome (null = never tested).
  final Map<String, bool> _tested = {};
  String? _checking;

  @override
  void initState() {
    super.initState();
    _lines = List<String>.from(widget.initialLines);
    _newLineController = TextEditingController();
  }

  @override
  void dispose() {
    _newLineController.dispose();
    super.dispose();
  }

  EmbyClient _client() {
    const dummy = EmbyServerConfig(baseUrl: '', apiKey: '');
    return widget.clientFactory?.call(dummy) ?? EmbyClient(config: dummy);
  }

  void _addLine() {
    final raw = _newLineController.text.trim();
    if (raw.isEmpty) return;
    final address = EmbyServerAddress.parse(raw);
    if (address.host.isEmpty) {
      HaoToast.show('地址不对', message: '请输入服务器域名或 IP');
      return;
    }
    final url = address.baseUrl;
    if (_lines.contains(url)) {
      HaoToast.show('这条线路已经加过了');
      return;
    }
    setState(() {
      _lines.add(url);
      _newLineController.clear();
    });
  }

  Future<void> _testLine(String line) async {
    setState(() => _checking = line);
    final ok = await _client().checkPublicLine(line);
    if (!mounted) return;
    setState(() {
      _checking = null;
      _tested[line] = ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.ofOrDefault(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.of(context).pop(_lines);
      },
      child: Scaffold(
        appBar: HaoNavBar(
          title: '备用线路',
          actions: [HaoNavBarTextButton(label: '完成', onPressed: () => Navigator.of(context).pop(_lines))],
        ),
        body: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const HaoHint('主线路连不上时，连接会按顺序尝试这里的地址。Emby 没有提供从服务器获取备用线路的接口，只能手动添加。'),
            const SizedBox(height: 16),
            SettingsGroup(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('emby_fallback_new'),
                          controller: _newLineController,
                          keyboardType: TextInputType.url,
                          onSubmitted: (_) => _addLine(),
                          decoration: InputDecoration.collapsed(
                            hintText: '如 http://192.168.1.11:8096',
                            hintStyle: TextStyle(
                              color: theme.textMuted,
                              fontSize: 16,
                            ),
                          ),
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _addLine,
                        child: const Text('添加'),
                      ),
                    ],
                  ),
                ),
                for (final line in _lines) ...[
                  ListTile(
                    title: Text(
                      line,
                      style: TextStyle(color: theme.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: _tested[line] == null
                        ? null
                        : Text(
                            _tested[line]!
                                ? '是 Emby 服务器'
                                : '连不上这个地址',
                            style: TextStyle(
                              color: _tested[line]!
                                  ? theme.accent
                                  : theme.liveRed,
                            ),
                          ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: _checking == line
                              ? null
                              : () => _testLine(line),
                          child: Text(_checking == line ? '测…' : '测'),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.delete_outline,
                            color: theme.textSecondary,
                            shadows: HaoTheme.legibilityShadows(context),
                          ),
                          tooltip: '删除',
                          onPressed: () =>
                              setState(() => _lines.remove(line)),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            if (_lines.isEmpty) ...[
              const SizedBox(height: 16),
              const HaoHint('还没有备用线路。'),
            ],
          ],
        ),
      ),
    );
  }
}
