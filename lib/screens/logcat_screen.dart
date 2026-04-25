import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/adb_service.dart';
import '../utils/theme.dart';
import '../widgets/device_card.dart';

class LogcatScreen extends StatefulWidget {
  const LogcatScreen({super.key});
  @override
  State<LogcatScreen> createState() => _LogcatScreenState();
}

class _LogcatScreenState extends State<LogcatScreen> {
  final List<LogLine> _lines = [];
  final ScrollController _scroll = ScrollController();
  StreamSubscription<String>? _sub;
  bool _running = false;
  bool _autoScroll = true;
  String _levelFilter = 'V';
  String _textFilter = '';
  final _filterCtrl = TextEditingController();
  static const int _maxLines = 2000;

  final _levels = ['V', 'D', 'I', 'W', 'E'];

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }

  Future<void> _startLogcat() async {
    final adb = context.read<AdbService>();
    if (!adb.hasDevice) return;
    setState(() { _running = true; _lines.clear(); });

    _sub = adb.logcat(level: _levelFilter).listen(
      (line) {
        final parsed = LogLine.parse(line);
        if (_textFilter.isNotEmpty &&
            !line.toLowerCase().contains(_textFilter.toLowerCase())) {
          return;
        }
        setState(() {
          _lines.add(parsed);
          if (_lines.length > _maxLines) {
            _lines.removeRange(0, _lines.length - _maxLines);
          }
        });
        if (_autoScroll) _scrollToBottom();
      },
      onDone: () => setState(() => _running = false),
      onError: (_) => setState(() => _running = false),
    );
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    setState(() => _running = false);
  }

  void _clear() => setState(() => _lines.clear());

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  List<LogLine> get _filtered {
    if (_textFilter.isEmpty) return _lines;
    return _lines.where((l) =>
      l.raw.toLowerCase().contains(_textFilter.toLowerCase())).toList();
  }

  @override
  Widget build(BuildContext context) {
    final adb = context.watch<AdbService>();

    if (!adb.hasDevice) {
      return Scaffold(
        backgroundColor: AppTheme.bg0,
        body: NoDevicePlaceholder(
          onConnect: () => Navigator.pushNamed(context, '/connect'),
        ),
      );
    }

    final filtered = _filtered;

    return Scaffold(
      backgroundColor: AppTheme.bg0,
      appBar: AppBar(
        title: Row(children: [
          const Text('日志'),
          const SizedBox(width: 10),
          if (_running)
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                color: AppTheme.danger,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: AppTheme.danger.withOpacity(0.5), blurRadius: 4),
                ],
              ),
            ),
        ]),
        actions: [
          // Level filter chips
          ...['W', 'E'].map((l) => Padding(
            padding: const EdgeInsets.only(right: 4),
            child: FilterChip(
              label: Text(l, style: TextStyle(
                fontFamily: 'SpaceMono', fontSize: 10,
                color: _levelFilter == l ? AppTheme.bg0 : _levelColor(l),
                fontWeight: FontWeight.w700,
              )),
              selected: _levelFilter == l,
              selectedColor: _levelColor(l),
              backgroundColor: AppTheme.bg2,
              side: BorderSide(color: _levelColor(l).withOpacity(0.4)),
              checkmarkColor: AppTheme.bg0,
              padding: EdgeInsets.zero,
              onSelected: (v) {
                setState(() => _levelFilter = v ? l : 'V');
                if (_running) { _stop(); _startLogcat(); }
              },
              visualDensity: VisualDensity.compact,
            ),
          )),
          IconButton(
            icon: const Icon(Icons.delete_sweep_rounded, size: 20),
            onPressed: _clear,
            color: AppTheme.textMuted,
          ),
          IconButton(
            icon: Icon(
              _autoScroll ? Icons.vertical_align_bottom_rounded : Icons.pause_rounded,
              size: 20,
            ),
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
            color: _autoScroll ? AppTheme.primary : AppTheme.textMuted,
            tooltip: _autoScroll ? '自动滚动已开启' : '自动滚动已关闭',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: TextField(
              controller: _filterCtrl,
              onChanged: (v) => setState(() => _textFilter = v),
              decoration: InputDecoration(
                hintText: '过滤日志...',
                prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppTheme.textMuted),
                suffixIcon: _textFilter.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded, size: 16, color: AppTheme.textMuted),
                        onPressed: () { _filterCtrl.clear(); setState(() => _textFilter = ''); },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
        ),
      ),
      body: Column(children: [
        // Stats bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.bg3)),
          ),
          child: Row(children: [
            Text('${filtered.length} lines', style: const TextStyle(
              fontFamily: 'SpaceMono', fontSize: 10,
              color: AppTheme.textMuted, letterSpacing: 0.5,
            )),
            if (_textFilter.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text('filtered', style: TextStyle(
                fontFamily: 'SpaceMono', fontSize: 10,
                color: AppTheme.primary.withOpacity(0.7),
              )),
            ],
            const Spacer(),
            // Level selector
            Row(children: _levels.map((l) => GestureDetector(
              onTap: () {
                setState(() => _levelFilter = l);
                if (_running) { _stop(); _startLogcat(); }
              },
              child: Container(
                margin: const EdgeInsets.only(left: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _levelFilter == l
                      ? _levelColor(l).withOpacity(0.2) : AppTheme.bg2,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color: _levelFilter == l
                        ? _levelColor(l) : AppTheme.bg3,
                  ),
                ),
                child: Text(l, style: TextStyle(
                  fontFamily: 'SpaceMono', fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: _levelFilter == l ? _levelColor(l) : AppTheme.textMuted,
                )),
              ),
            )).toList()),
          ]),
        ),

        // Log lines
        Expanded(
          child: filtered.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                    _running ? Icons.hourglass_empty_rounded : Icons.list_alt_rounded,
                    size: 36, color: AppTheme.textMuted,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _running ? 'Waiting for logs...' : 'Press ▶ to start',
                    style: const TextStyle(
                      fontFamily: 'SpaceMono', fontSize: 13,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ]))
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: filtered.length,
                  itemBuilder: (ctx, i) => _LogLineWidget(line: filtered[i]),
                ),
        ),
      ]),
      floatingActionButton: FloatingActionButton(
        onPressed: _running ? _stop : _startLogcat,
        backgroundColor: _running ? AppTheme.danger : AppTheme.primary,
        foregroundColor: AppTheme.bg0,
        tooltip: _running ? '停止' : '启动 Logcat',
        child: Icon(
          _running ? Icons.stop_rounded : Icons.play_arrow_rounded,
          size: 24,
        ),
      ),
    );
  }

  Color _levelColor(String level) => switch (level) {
    'E' => AppTheme.danger,
    'W' => AppTheme.warning,
    'I' => AppTheme.success,
    'D' => AppTheme.secondary,
    _   => AppTheme.textMuted,
  };
}

// ── Log Line Model ────────────────────────────────────────────────────────────

class LogLine {
  final String raw;
  final String time;
  final String level;
  final String tag;
  final String message;

  LogLine({
    required this.raw,
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
  });

  factory LogLine.parse(String line) {
    // Format: "01-01 12:00:00.000  1234  1234 D Tag: message"
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 6) {
      return LogLine(raw: line, time: '', level: 'V', tag: '', message: line);
    }
    try {
      final time = '${parts[0]} ${parts[1]}';
      final level = parts[4];
      final tagRaw = parts[5];
      final tag = tagRaw.endsWith(':') ? tagRaw.substring(0, tagRaw.length - 1) : tagRaw;
      final message = parts.sublist(6).join(' ');
      return LogLine(raw: line, time: time, level: level, tag: tag, message: message);
    } catch (_) {
      return LogLine(raw: line, time: '', level: 'V', tag: '', message: line);
    }
  }
}

// ── Log Line Widget ───────────────────────────────────────────────────────────

class _LogLineWidget extends StatelessWidget {
  final LogLine line;
  const _LogLineWidget({required this.line});

  Color get _color => switch (line.level) {
    'E' => AppTheme.danger,
    'W' => AppTheme.warning,
    'I' => AppTheme.success,
    'D' => AppTheme.secondary,
    _   => AppTheme.textSecondary,
  };

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: line.raw));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Level badge
          Container(
            width: 16, height: 16,
            margin: const EdgeInsets.only(top: 2, right: 6),
            decoration: BoxDecoration(
              color: _color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Center(child: Text(line.level, style: TextStyle(
              fontFamily: 'SpaceMono', fontSize: 9,
              fontWeight: FontWeight.w700, color: _color,
            ))),
          ),
          // Content
          Expanded(child: Text.rich(TextSpan(children: [
            if (line.tag.isNotEmpty) TextSpan(
              text: '${line.tag} ',
              style: TextStyle(
                fontFamily: 'SpaceMono', fontSize: 10,
                fontWeight: FontWeight.w600, color: _color.withOpacity(0.8),
              ),
            ),
            TextSpan(
              text: line.message,
              style: TextStyle(
                fontFamily: 'JetBrainsMono', fontSize: 11,
                color: line.level == 'E'
                    ? AppTheme.danger.withOpacity(0.9)
                    : AppTheme.textSecondary,
                height: 1.5,
              ),
            ),
          ]))),
        ]),
      ),
    );
  }
}
