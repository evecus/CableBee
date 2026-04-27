import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/adb_service.dart';
import '../utils/theme.dart';

class ShellScreen extends StatefulWidget {
  final void Function(List<Widget> actions)? onActionsChanged;
  const ShellScreen({super.key, this.onActionsChanged});
  @override
  State<ShellScreen> createState() => ShellScreenState();
}

class ShellScreenState extends State<ShellScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  void refreshActions() => _pushActions();

  final _inputCtrl   = TextEditingController();
  final _scrollCtrl  = ScrollController();
  final _focusNode   = FocusNode();

  final List<_ShellEntry> _entries = [];
  final List<String>      _history = [];
  int  _historyIndex = -1;
  bool _running      = false;

  // ── 工作目录跟踪 ──────────────────────────────────────────────────────────
  String _cwd = '/';   // 当前工作目录，初始为根目录

  final _quickCmds = const [
    ('ps',              'processes'),
    ('top -n 1',        'cpu'),
    ('df -h',           'disk'),
    ('netstat',         'net'),
    ('logcat -d',       'log'),
    ('dumpsys battery', 'battery'),
    ('getprop',         'props'),
    ('pm list packages -3', 'apps'),
    ('wm size',         'screen'),
    ('wm density',      'dpi'),
    ('id',              'whoami'),
    ('uname -a',        'kernel'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _pushActions();
      await _initCwd();
    });
  }

  /// 启动时获取设备真实起始目录（通常是 /）
  Future<void> _initCwd() async {
    try {
      final adb = context.read<AdbService>();
      final res = await adb.shell('pwd');
      final pwd = res.stdout.trim();
      if (pwd.startsWith('/')) setState(() => _cwd = pwd);
    } catch (_) {}
  }

  void _pushActions() {
    widget.onActionsChanged?.call([
      IconButton(
        icon: const Icon(Icons.delete_sweep_rounded, size: 20),
        onPressed: _clear,
        tooltip: '清空',
        color: AppTheme.textMuted,
      ),
      IconButton(
        icon: const Icon(Icons.copy_all_rounded, size: 20),
        onPressed: () {
          final all = _entries.map((e) => e.content).join('\n');
          Clipboard.setData(ClipboardData(text: all));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已复制全部输出')),
          );
        },
        tooltip: '复制全部',
        color: AppTheme.textMuted,
      ),
    ]);
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── 解析 cd 并更新 _cwd ──────────────────────────────────────────────────

  /// 根据当前 _cwd 和用户输入的 cd 参数，计算新路径（不联网，纯字符串）。
  String _resolveCd(String arg) {
    arg = arg.trim();
    if (arg.isEmpty || arg == '~') return '/sdcard';
    if (arg.startsWith('/'))      return _normalize(arg);
    if (arg == '..')              return _parent(_cwd);
    if (arg == '.')               return _cwd;
    // 相对路径
    return _normalize('$_cwd/$arg');
  }

  String _parent(String path) {
    if (path == '/') return '/';
    final parts = path.split('/')..removeLast();
    final p = parts.join('/');
    return p.isEmpty ? '/' : p;
  }

  String _normalize(String path) {
    final parts = <String>[];
    for (final seg in path.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') { if (parts.isNotEmpty) parts.removeLast(); }
      else parts.add(seg);
    }
    return '/${parts.join('/')}';
  }

  // ── 命令执行 ─────────────────────────────────────────────────────────────

  Future<void> _run(String rawCmd) async {
    final cmd = rawCmd.trim();
    if (cmd.isEmpty) return;
    final adb = context.read<AdbService>();

    if (_history.isEmpty || _history.last != cmd) _history.add(cmd);
    _historyIndex = -1;

    // ── 处理 cd 命令 ───────────────────────────────────────────────────────
    // 支持: cd、cd <path>、cd .. 及 cd 内嵌在 && 链中（仅处理独立 cd）
    final cdOnly = RegExp(r'^cd\s*(.*)$');
    final cdMatch = cdOnly.firstMatch(cmd);
    if (cdMatch != null) {
      final arg       = cdMatch.group(1)!.trim();
      final candidate = _resolveCd(arg);

      setState(() {
        _entries.add(_ShellEntry.command(cmd, cwd: _cwd));
        _running = true;
      });
      _inputCtrl.clear();
      _scrollToBottom();

      // 验证目录是否存在
      final checkRes = await adb.shell('[ -d "$candidate" ] && echo OK || echo FAIL');
      final ok = checkRes.stdout.trim() == 'OK';

      setState(() {
        _running = false;
        if (ok) {
          _cwd = candidate;
          _entries.add(_ShellEntry.output(
            '→ $_cwd',
            isError: false,
            muted: true,
          ));
        } else {
          _entries.add(_ShellEntry.output(
            'cd: $candidate: No such file or directory',
            isError: true,
          ));
        }
      });
      _scrollToBottom();
      return;
    }

    // ── 普通命令：在 _cwd 下执行 ──────────────────────────────────────────
    setState(() {
      _entries.add(_ShellEntry.command(cmd, cwd: _cwd));
      _running = true;
    });
    _inputCtrl.clear();
    _scrollToBottom();

    // 包装为 cd <cwd> && <cmd>，保证命令在正确目录下执行
    final wrapped = 'cd "$_cwd" 2>/dev/null; $cmd';
    final result  = await adb.shell(wrapped);

    // 如果命令中含 cd（如 cd /x && ls），执行后同步一下真实 pwd
    if (cmd.contains('cd ')) {
      try {
        final pwdRes = await adb.shell('cd "$_cwd" 2>/dev/null; $cmd; pwd');
        final lines  = pwdRes.stdout.trim().split('\n');
        final last   = lines.last.trim();
        if (last.startsWith('/')) setState(() => _cwd = last);
      } catch (_) {}
    }

    setState(() {
      _running = false;
      final output = result.stdout.trim();
      final err    = result.stderr.trim();
      if (output.isNotEmpty) _entries.add(_ShellEntry.output(output, isError: false));
      if (err.isNotEmpty)    _entries.add(_ShellEntry.output(err,    isError: true));
      if (output.isEmpty && err.isEmpty)
        _entries.add(_ShellEntry.output('(no output)', isError: false, muted: true));
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _navigateHistory(int dir) {
    if (_history.isEmpty) return;
    setState(() {
      _historyIndex = (_historyIndex - dir).clamp(-1, _history.length - 1);
      if (_historyIndex == -1) {
        _inputCtrl.clear();
      } else {
        final idx = _history.length - 1 - _historyIndex;
        _inputCtrl.text = _history[idx];
        _inputCtrl.selection = TextSelection.collapsed(offset: _inputCtrl.text.length);
      }
    });
  }

  void _clear() => setState(() => _entries.clear());

  // ── 构建 UI ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final adb = context.watch<AdbService>();

    return Material(
      color: AppTheme.bg0,
      child: Column(children: [
        // 快捷命令行
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: _quickCmds.map((e) {
              final (cmd, label) = e;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  label: Text(label, style: const TextStyle(
                    fontFamily: 'SpaceMono', fontSize: 11,
                    color: AppTheme.textSecondary,
                  )),
                  backgroundColor: AppTheme.bg1,
                  side: const BorderSide(color: AppTheme.bg3),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  onPressed: () => _run(cmd),
                  visualDensity: VisualDensity.compact,
                ),
              );
            }).toList(),
          ),
        ),
        const Divider(height: 1),

        // 输出区
        Expanded(
          child: _entries.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.terminal_rounded, size: 36, color: AppTheme.textMuted),
                  const SizedBox(height: 12),
                  Text(
                    '\$ ${adb.selectedDevice!.serial}',
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono', fontSize: 12,
                      color: AppTheme.textMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text('Type a command below', style: TextStyle(
                    fontFamily: 'JetBrainsMono', fontSize: 11,
                    color: AppTheme.textMuted,
                  )),
                ]))
              : ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  itemCount: _entries.length + (_running ? 1 : 0),
                  itemBuilder: (ctx, i) {
                    if (_running && i == _entries.length) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          SizedBox(
                            width: 12, height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              valueColor: AlwaysStoppedAnimation(AppTheme.primary),
                            ),
                          ),
                          SizedBox(width: 10),
                          Text('running...', style: TextStyle(
                            fontFamily: 'JetBrainsMono', fontSize: 11,
                            color: AppTheme.textMuted,
                          )),
                        ]),
                      );
                    }
                    return _EntryWidget(entry: _entries[i]);
                  },
                ),
        ),
        const Divider(height: 1),

        // 路径提示栏
        Container(
          width: double.infinity,
          color: AppTheme.bg1,
          padding: const EdgeInsets.fromLTRB(16, 5, 16, 5),
          child: Row(children: [
            const Icon(Icons.folder_open_rounded, size: 13, color: AppTheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _cwd,
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11,
                  color: AppTheme.primary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // 快速跳转常用目录
            _CwdShortcut(label: '/', onTap: () => _run('cd /')),
            _CwdShortcut(label: '~', onTap: () => _run('cd /sdcard')),
            _CwdShortcut(label: '..', onTap: () => _run('cd ..')),
          ]),
        ),

        // 输入栏
        Container(
          color: AppTheme.bg1,
          padding: EdgeInsets.fromLTRB(
            12, 6, 12, MediaQuery.of(context).viewInsets.bottom + 6,
          ),
          child: Row(children: [
            const Text('\$ ', style: TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 14,
              color: AppTheme.primary, fontWeight: FontWeight.w700,
            )),
            Expanded(
              child: TextField(
                controller: _inputCtrl,
                focusNode: _focusNode,
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono', fontSize: 13,
                  color: AppTheme.textPrimary,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: '输入命令...',
                  fillColor: Colors.transparent,
                  filled: false,
                ),
                onSubmitted: _run,
                textInputAction: TextInputAction.send,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 20),
              onPressed: () => _navigateHistory(1),
              color: AppTheme.textMuted,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
              onPressed: () => _navigateHistory(-1),
              color: AppTheme.textMuted,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
            GestureDetector(
              onTap: () => _run(_inputCtrl.text),
              child: Container(
                width: 34, height: 34,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
                ),
                child: const Icon(Icons.send_rounded, size: 16, color: AppTheme.primary),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ── 路径快捷按钮 ──────────────────────────────────────────────────────────────

class _CwdShortcut extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _CwdShortcut({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: AppTheme.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppTheme.primary.withOpacity(0.25)),
        ),
        child: Text(label, style: const TextStyle(
          fontFamily: 'JetBrainsMono', fontSize: 11,
          color: AppTheme.primary,
        )),
      ),
    );
  }
}

// ── Shell Entry Model ─────────────────────────────────────────────────────────

enum _EntryType { command, output }

class _ShellEntry {
  final _EntryType type;
  final String     content;
  final bool       isError;
  final bool       muted;
  final String?    cwd;   // 执行命令时的工作目录，仅 command 类型使用
  final DateTime   time;

  _ShellEntry._({
    required this.type,
    required this.content,
    this.isError = false,
    this.muted   = false,
    this.cwd,
  }) : time = DateTime.now();

  factory _ShellEntry.command(String cmd, {String? cwd}) =>
      _ShellEntry._(type: _EntryType.command, content: cmd, cwd: cwd);
  factory _ShellEntry.output(String text, {required bool isError, bool muted = false}) =>
      _ShellEntry._(type: _EntryType.output, content: text, isError: isError, muted: muted);
}

// ── Shell Entry Widget ────────────────────────────────────────────────────────

class _EntryWidget extends StatelessWidget {
  final _ShellEntry entry;
  const _EntryWidget({required this.entry});

  @override
  Widget build(BuildContext context) {
    if (entry.type == _EntryType.command) {
      return Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // 路径提示（dim 色）
          if (entry.cwd != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                entry.cwd!,
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono', fontSize: 10,
                  color: AppTheme.textMuted,
                ),
              ),
            ),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('\$ ', style: TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 13,
              color: AppTheme.primary, fontWeight: FontWeight.w700,
            )),
            Expanded(child: Text(entry.content, style: const TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 13,
              color: AppTheme.textPrimary, fontWeight: FontWeight.w600,
            ))),
          ]),
        ]),
      );
    }

    // Output
    Color color;
    if (entry.muted) {
      color = AppTheme.textMuted;
    } else if (entry.isError) {
      color = AppTheme.danger.withOpacity(0.85);
    } else {
      color = AppTheme.textSecondary;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 16),
      child: SelectableText(
        entry.content,
        style: TextStyle(
          fontFamily: 'JetBrainsMono', fontSize: 12,
          color: color, height: 1.55,
        ),
      ),
    );
  }
}
