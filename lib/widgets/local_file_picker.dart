import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/theme.dart';

// ── 排序方式 ───────────────────────────────────────────────────────────────────

enum SortBy { name, size, modified }
enum SortOrder { asc, desc }

// ── 文件条目 ───────────────────────────────────────────────────────────────────

class LocalFileEntry {
  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime modified;

  const LocalFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modified,
  });
}

// ── 入口函数：弹出本机文件选择器，返回选中的路径列表 ─────────────────────────

Future<List<String>?> showLocalFilePicker(
  BuildContext context, {
  bool allowMultiple = false,
  bool allowFolders = true,
  String? initialPath,
}) async {
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _LocalFilePickerSheet(
      allowMultiple: allowMultiple,
      allowFolders: allowFolders,
      initialPath: initialPath,
    ),
  );
}

// ── 底部弹出面板 ───────────────────────────────────────────────────────────────

class _LocalFilePickerSheet extends StatefulWidget {
  final bool allowMultiple;
  final bool allowFolders;
  final String? initialPath;

  const _LocalFilePickerSheet({
    required this.allowMultiple,
    required this.allowFolders,
    this.initialPath,
  });

  @override
  State<_LocalFilePickerSheet> createState() => _LocalFilePickerSheetState();
}

class _LocalFilePickerSheetState extends State<_LocalFilePickerSheet> {
  late String _currentPath;
  List<LocalFileEntry> _entries = [];
  final List<String> _breadcrumbs = [];
  bool _loading = false;
  String? _error;

  final Set<String> _selected = {};
  SortBy _sortBy = SortBy.name;
  SortOrder _sortOrder = SortOrder.asc;

  static const _roots = [
    '/storage/emulated/0',
    '/sdcard',
    '/storage',
  ];

  @override
  void initState() {
    super.initState();
    _requestPermissionAndLoad();
  }

  Future<void> _requestPermissionAndLoad() async {
    // Android 11+: MANAGE_EXTERNAL_STORAGE; Android 10-: READ_EXTERNAL_STORAGE
    if (Platform.isAndroid) {
      final manageStatus = await Permission.manageExternalStorage.status;
      if (manageStatus.isDenied || manageStatus.isPermanentlyDenied) {
        await Permission.manageExternalStorage.request();
      }
      // 低版本降级申请
      final readStatus = await Permission.storage.status;
      if (readStatus.isDenied) {
        await Permission.storage.request();
      }
    }
    // 找到第一个存在的根目录
    String startPath = widget.initialPath ?? '';
    if (startPath.isEmpty || !Directory(startPath).existsSync()) {
      startPath = _roots.firstWhere(
        (p) => Directory(p).existsSync(),
        orElse: () => '/storage/emulated/0',
      );
    }
    _currentPath = startPath;
    _breadcrumbs.add(startPath);
    _loadDir(startPath);
  }

  Future<void> _loadDir(String path) async {
    setState(() { _loading = true; _error = null; });
    try {
      final dir = Directory(path);
      final list = await dir.list().toList();
      final entries = <LocalFileEntry>[];
      for (final entity in list) {
        try {
          final stat = await entity.stat();
          final name = entity.path.split('/').last;
          if (name.startsWith('.')) continue; // 跳过隐藏文件
          entries.add(LocalFileEntry(
            name: name,
            path: entity.path,
            isDirectory: entity is Directory,
            size: stat.size,
            modified: stat.modified,
          ));
        } catch (_) {}
      }
      _sortEntries(entries);
      setState(() {
        _entries = entries;
        _currentPath = path;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _sortEntries(List<LocalFileEntry> entries) {
    entries.sort((a, b) {
      // 文件夹始终在前
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;
      int cmp;
      switch (_sortBy) {
        case SortBy.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case SortBy.size:
          cmp = a.size.compareTo(b.size);
        case SortBy.modified:
          cmp = a.modified.compareTo(b.modified);
      }
      return _sortOrder == SortOrder.asc ? cmp : -cmp;
    });
  }

  void _applySort() {
    final sorted = List<LocalFileEntry>.from(_entries);
    _sortEntries(sorted);
    setState(() => _entries = sorted);
  }

  void _navigate(LocalFileEntry entry) {
    if (!entry.isDirectory) return;
    _breadcrumbs.add(entry.path);
    _loadDir(entry.path);
  }

  void _navigateTo(String path) {
    final idx = _breadcrumbs.indexOf(path);
    if (idx >= 0) {
      _breadcrumbs.removeRange(idx + 1, _breadcrumbs.length);
    }
    _loadDir(path);
  }

  void _navigateUp() {
    if (_breadcrumbs.length <= 1) {
      Navigator.pop(context);
      return;
    }
    _breadcrumbs.removeLast();
    _loadDir(_breadcrumbs.last);
  }

  void _toggleSelect(LocalFileEntry entry) {
    if (!widget.allowFolders && entry.isDirectory) return;
    setState(() {
      if (_selected.contains(entry.path)) {
        _selected.remove(entry.path);
      } else {
        if (!widget.allowMultiple) _selected.clear();
        _selected.add(entry.path);
      }
    });
  }

  void _toggleSelectAll() {
    final selectable = _entries
        .where((e) => !e.isDirectory || widget.allowFolders)
        .map((e) => e.path)
        .toList();
    final allSelected = selectable.every((p) => _selected.contains(p));
    setState(() {
      if (allSelected) {
        _selected.removeAll(selectable);
      } else {
        _selected.addAll(selectable);
      }
    });
  }

  void _confirm() {
    if (_selected.isEmpty) return;
    Navigator.pop(context, _selected.toList());
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')} '
        '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    final selectable = _entries.where((e) => !e.isDirectory || widget.allowFolders).toList();
    final allSelected = selectable.isNotEmpty &&
        selectable.every((e) => _selected.contains(e.path));

    return Container(
      height: screenH * 0.88,
      decoration: const BoxDecoration(
        color: AppTheme.bg0,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(children: [
        // ── 顶部把手 ──
        Container(
          margin: const EdgeInsets.only(top: 10, bottom: 4),
          width: 36, height: 4,
          decoration: BoxDecoration(
            color: AppTheme.bg3,
            borderRadius: BorderRadius.circular(2),
          ),
        ),

        // ── 标题栏 ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, size: 20, color: AppTheme.textSecondary),
              onPressed: _navigateUp,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
            const SizedBox(width: 4),
            const Text('选择文件', style: TextStyle(
              fontFamily: 'SpaceMono', fontSize: 15,
              fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
            )),
            const Spacer(),
            // 排序菜单
            _SortButton(
              sortBy: _sortBy,
              sortOrder: _sortOrder,
              onChanged: (by, order) {
                setState(() { _sortBy = by; _sortOrder = order; });
                _applySort();
              },
            ),
            if (widget.allowMultiple)
              TextButton(
                onPressed: _toggleSelectAll,
                child: Text(
                  allSelected ? '取消全选' : '全选',
                  style: const TextStyle(
                    fontFamily: 'SpaceMono', fontSize: 12, color: AppTheme.primary,
                  ),
                ),
              ),
          ]),
        ),

        // ── 面包屑 ──
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: _breadcrumbs.asMap().entries.expand((e) {
              final isLast = e.key == _breadcrumbs.length - 1;
              final label = e.key == 0
                  ? e.value.split('/').last.isEmpty ? '根目录' : e.value.split('/').last
                  : e.value.split('/').last;
              return [
                GestureDetector(
                  onTap: isLast ? null : () => _navigateTo(e.value),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(label, style: TextStyle(
                      fontFamily: 'JetBrainsMono', fontSize: 12,
                      color: isLast ? AppTheme.textPrimary : AppTheme.textMuted,
                      fontWeight: isLast ? FontWeight.w600 : FontWeight.w400,
                    )),
                  ),
                ),
                if (!isLast)
                  const Icon(Icons.chevron_right_rounded, size: 14, color: AppTheme.textMuted),
              ];
            }).toList(),
          ),
        ),

        const Divider(height: 1, color: AppTheme.bg3),

        // ── 文件列表 ──
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation(AppTheme.primary),
                ))
              : _error != null
                  ? Center(child: Text('无法访问\n$_error', textAlign: TextAlign.center,
                      style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12,
                        color: AppTheme.textMuted)))
                  : _entries.isEmpty
                      ? const Center(child: Text('空目录', style: TextStyle(
                          fontFamily: 'SpaceMono', fontSize: 13, color: AppTheme.textMuted)))
                      : ListView.separated(
                          itemCount: _entries.length,
                          separatorBuilder: (_, __) => const Divider(height: 1, indent: 56, color: AppTheme.bg3),
                          itemBuilder: (_, i) {
                            final entry = _entries[i];
                            final isSelected = _selected.contains(entry.path);
                            final canSelect = !entry.isDirectory || widget.allowFolders;

                            return InkWell(
                              onTap: () {
                                if (entry.isDirectory) {
                                  _navigate(entry);
                                } else {
                                  _toggleSelect(entry);
                                }
                              },
                              onLongPress: canSelect ? () => _toggleSelect(entry) : null,
                              child: Container(
                                color: isSelected
                                    ? AppTheme.primary.withOpacity(0.08)
                                    : Colors.transparent,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                child: Row(children: [
                                  // 选择框（仅 allowMultiple 模式或已选中时显示）
                                  if (widget.allowMultiple && canSelect)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 10),
                                      child: SizedBox(
                                        width: 20, height: 20,
                                        child: Checkbox(
                                          value: isSelected,
                                          onChanged: (_) => _toggleSelect(entry),
                                          activeColor: AppTheme.primary,
                                          side: const BorderSide(color: AppTheme.bg3, width: 1.5),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                        ),
                                      ),
                                    ),
                                  // 图标
                                  Container(
                                    width: 36, height: 36,
                                    decoration: BoxDecoration(
                                      color: _entryColor(entry).withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Icon(_entryIcon(entry), size: 18, color: _entryColor(entry)),
                                  ),
                                  const SizedBox(width: 12),
                                  // 名称 + 信息
                                  Expanded(child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(entry.name, style: const TextStyle(
                                        fontFamily: 'JetBrainsMono', fontSize: 13,
                                        color: AppTheme.textPrimary,
                                      ), maxLines: 1, overflow: TextOverflow.ellipsis),
                                      const SizedBox(height: 2),
                                      Text(
                                        entry.isDirectory
                                            ? _formatDate(entry.modified)
                                            : '${_formatSize(entry.size)}  ${_formatDate(entry.modified)}',
                                        style: const TextStyle(
                                          fontFamily: 'JetBrainsMono', fontSize: 10,
                                          color: AppTheme.textMuted,
                                        ),
                                      ),
                                    ],
                                  )),
                                  // 进入文件夹箭头
                                  if (entry.isDirectory)
                                    const Icon(Icons.chevron_right_rounded, size: 16, color: AppTheme.textMuted),
                                  // 单选模式下文件点击直接确认
                                  if (!widget.allowMultiple && !entry.isDirectory && isSelected)
                                    const Icon(Icons.check_circle_rounded, size: 18, color: AppTheme.primary),
                                ]),
                              ),
                            );
                          },
                        ),
        ),

        // ── 底部操作栏 ──
        const Divider(height: 1, color: AppTheme.bg3),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(children: [
              // 已选数量
              Expanded(child: Text(
                _selected.isEmpty
                    ? '未选择任何文件'
                    : '已选 ${_selected.length} 个',
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono', fontSize: 12,
                  color: AppTheme.textMuted,
                ),
              )),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消', style: TextStyle(
                  fontFamily: 'SpaceMono', color: AppTheme.textSecondary,
                )),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _selected.isNotEmpty ? _confirm : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: AppTheme.bg0,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  textStyle: const TextStyle(
                    fontFamily: 'SpaceMono', fontSize: 13, fontWeight: FontWeight.w700,
                  ),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('确认'),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  IconData _entryIcon(LocalFileEntry e) {
    if (e.isDirectory) return Icons.folder_rounded;
    final ext = e.name.split('.').last.toLowerCase();
    return switch (ext) {
      'img' || 'bin' || 'zip' || 'tar' || 'gz' || 'br' => Icons.archive_rounded,
      'apk' => Icons.android_rounded,
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' => Icons.image_rounded,
      'mp4' || 'mkv' || 'avi' => Icons.movie_rounded,
      'mp3' || 'aac' || 'flac' => Icons.audio_file_rounded,
      'pdf' => Icons.picture_as_pdf_rounded,
      'txt' || 'log' || 'xml' || 'json' => Icons.description_rounded,
      _ => Icons.insert_drive_file_rounded,
    };
  }

  Color _entryColor(LocalFileEntry e) {
    if (e.isDirectory) return AppTheme.warning;
    final ext = e.name.split('.').last.toLowerCase();
    return switch (ext) {
      'img' || 'bin' => AppTheme.primary,
      'apk' => AppTheme.success,
      'zip' || 'tar' || 'gz' => AppTheme.secondary,
      'jpg' || 'jpeg' || 'png' || 'gif' => const Color(0xFF9B59B6),
      'mp4' || 'mkv' => const Color(0xFFE74C3C),
      'pdf' => AppTheme.danger,
      _ => AppTheme.textMuted,
    };
  }
}

// ── 排序按钮 ───────────────────────────────────────────────────────────────────

class _SortButton extends StatelessWidget {
  final SortBy sortBy;
  final SortOrder sortOrder;
  final void Function(SortBy, SortOrder) onChanged;

  const _SortButton({
    required this.sortBy,
    required this.sortOrder,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.sort_rounded, size: 20, color: AppTheme.textSecondary),
      color: AppTheme.bg1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.bg3),
      ),
      onSelected: (val) {
        final parts = val.split(':');
        final by = SortBy.values.firstWhere((e) => e.name == parts[0]);
        final order = parts[1] == 'asc' ? SortOrder.asc : SortOrder.desc;
        onChanged(by, order);
      },
      itemBuilder: (_) => [
        _sortItem('名称↑', 'name:asc', sortBy == SortBy.name && sortOrder == SortOrder.asc),
        _sortItem('名称↓', 'name:desc', sortBy == SortBy.name && sortOrder == SortOrder.desc),
        _sortItem('大小↑', 'size:asc', sortBy == SortBy.size && sortOrder == SortOrder.asc),
        _sortItem('大小↓', 'size:desc', sortBy == SortBy.size && sortOrder == SortOrder.desc),
        _sortItem('时间↑', 'modified:asc', sortBy == SortBy.modified && sortOrder == SortOrder.asc),
        _sortItem('时间↓', 'modified:desc', sortBy == SortBy.modified && sortOrder == SortOrder.desc),
      ],
    );
  }

  PopupMenuItem<String> _sortItem(String label, String value, bool active) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(children: [
        if (active)
          const Icon(Icons.check_rounded, size: 14, color: AppTheme.primary)
        else
          const SizedBox(width: 14),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(
          fontFamily: 'SpaceMono', fontSize: 12,
          color: active ? AppTheme.primary : AppTheme.textPrimary,
        )),
      ]),
    );
  }
}
