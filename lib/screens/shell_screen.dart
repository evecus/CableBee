import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/adb_service.dart';
import '../utils/theme.dart';

class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});
  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _focusNode = FocusNode();

  final List<_ShellEntry> _entries = [];
  final List<String> _history = [];
  int _historyIndex = -1;
  bool _running = false;

  // Quick commands
  final _quickCmds = const [
    ('ps', 'processes'),
    ('top -n 1', 'cpu'),
    ('df -h', 'disk'),
    ('netstat', 'net'),
    ('logcat -d', 'log'),
    ('dumpsys battery', 'battery'),
    ('getprop', 'props'),
    ('pm list packages -3', 'apps'),
    ('wm size', 'screen'),
    ('wm density', 'dpi'),
    ('id', 'whoami'),
    ('uname -a', 'kernel'),
  ];

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _run(String cmd) async {
    if (cmd.trim().isEmpty) return;
    final adb = context.read<AdbService>();

    // History
    if (_history.isEmpty || _history.last != cmd) _history.add(cmd);
    _historyIndex = -1;

    setState(() {
      _entries.add(_ShellEntry.command(cmd));
      _running = true;
    });
    _inputCtrl.clear();
    _scrollToBottom();

    final result = await adb.shell(cmd);

    setState(() {
      _running = false;
      final output = result.stdout.trim();
      final err = result.stderr.trim();
      if (output.isNotEmpty) {
        _entries.add(_ShellEntry.output(output, isError: false));
      }
      if (err.isNotEmpty) {
        _entries.add(_ShellEntry.output(err, isError: true));
      }
      if (output.isEmpty && err.isEmpty) {
        _entries.add(_ShellEntry.output('(no output)', isError: false, muted: true));
      }
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final adb = context.watch<AdbService>();

    return Scaffold(
      backgroundColor: AppTheme.bg0,
      appBar: AppBar(
        title: const Text('Shell'),
        actions: [
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
        ],
      ),
      body: Column(children: [
        // Quick commands horizontal scroll
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

        // Terminal output
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

        // Input bar
        Container(
          color: AppTheme.bg1,
          padding: EdgeInsets.fromLTRB(
            12, 8, 12, MediaQuery.of(context).viewInsets.bottom + 8,
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
            // History buttons
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
            // Send button
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

// ── Shell Entry Model ─────────────────────────────────────────────────────────

enum _EntryType { command, output }

class _ShellEntry {
  final _EntryType type;
  final String content;
  final bool isError;
  final bool muted;
  final DateTime time;

  _ShellEntry._({
    required this.type,
    required this.content,
    this.isError = false,
    this.muted = false,
  }) : time = DateTime.now();

  factory _ShellEntry.command(String cmd) =>
      _ShellEntry._(type: _EntryType.command, content: cmd);
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
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('\$ ', style: TextStyle(
            fontFamily: 'JetBrainsMono', fontSize: 13,
            color: AppTheme.primary, fontWeight: FontWeight.w700,
          )),
          Expanded(child: Text(entry.content, style: const TextStyle(
            fontFamily: 'JetBrainsMono', fontSize: 13,
            color: AppTheme.textPrimary, fontWeight: FontWeight.w600,
          ))),
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
