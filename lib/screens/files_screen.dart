import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/adb_service.dart';
import '../utils/theme.dart';
import '../widgets/common.dart';
import '../widgets/local_file_picker.dart';

// ─────────────────────────────────────────────────────────────
//  排序方式枚举
// ─────────────────────────────────────────────────────────────
enum SortMode { name, time, size }

// ─────────────────────────────────────────────────────────────
//  FilesScreen
// ─────────────────────────────────────────────────────────────
class FilesScreen extends StatefulWidget {
  final void Function(List<Widget> actions)? onActionsChanged;
  const FilesScreen({super.key, this.onActionsChanged});
  @override
  State<FilesScreen> createState() => FilesScreenState();
}

class FilesScreenState extends State<FilesScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  void refreshActions() => _pushActions();

  // ── 状态 ──
  String _currentPath = '/sdcard';
  List<FileEntry> _entries = [];
  bool _loading = false;
  bool _transferring = false;
  String? _transferMessage;
  SortMode _sortMode = SortMode.name;

  // 多选模式
  bool _multiSelect = false;
  final Set<String> _selected = {};

  // 默认下载路径
  String _downloadPath = '/sdcard/download/cablebee';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadPrefs();
      _loadDir(_currentPath);
      _pushActions();
    });
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _downloadPath =
          prefs.getString('download_path') ?? '/sdcard/download/cablebee';
    });
  }

  void _pushActions() {
    widget.onActionsChanged?.call([
      _QuickEntryButton(onNavigate: _navigateTo),
      _MoreMenuButton(
        onRefresh: () => _loadDir(_currentPath),
        currentSort: _sortMode,
        onSortChanged: (m) {
          setState(() => _sortMode = m);
          _applySortAndSet(_entries);
        },
      ),
    ]);
  }

  Future<void> _loadDir(String path) async {
    final adb = context.read<AdbService>();
    setState(() {
      _loading = true;
      _multiSelect = false;
      _selected.clear();
    });
    final entries = await adb.listFiles(path);
    _applySortAndSet(entries, newPath: path);
  }

  void _applySortAndSet(List<FileEntry> raw, {String? newPath}) {
    final sorted = List<FileEntry>.from(raw);
    sorted.sort((a, b) {
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;
      switch (_sortMode) {
        case SortMode.name:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case SortMode.time:
          return b.date.compareTo(a.date);
        case SortMode.size:
          final sa = int.tryParse(a.size) ?? 0;
          final sb = int.tryParse(b.size) ?? 0;
          return sb.compareTo(sa);
      }
    });
    setState(() {
      if (newPath != null) _currentPath = newPath;
      _entries = sorted;
      _loading = false;
    });
  }

  void _navigate(FileEntry entry) {
    if (!entry.isDirectory) return;
    final newPath = '$_currentPath/${entry.name}'.replaceAll('//', '/');
    _loadDir(newPath);
  }

  void _navigateTo(String path) => _loadDir(path);

  void _navigateUp() {
    if (_currentPath == '/' || _currentPath.isEmpty) return;
    final parts = _currentPath.split('/')..removeLast();
    final parent =
        parts.isEmpty || parts.join('/').isEmpty ? '/' : parts.join('/');
    _loadDir(parent);
  }

  Future<void> _pushFile() async {
    final results = await showLocalFilePicker(
      context,
      allowMultiple: true,
      allowFolders: false,
    );
    if (results == null || results.isEmpty) return;
    for (final localPath in results) {
      final fileName = localPath.split('/').last;
      final remotePath = '$_currentPath/$fileName';
      setState(() {
        _transferring = true;
        _transferMessage = '上传 $fileName...';
      });
      final res =
          await context.read<AdbService>().push(localPath, remotePath);
      setState(() {
        _transferring = false;
        _transferMessage =
            res.isSuccess ? '✓ 已上传 $fileName' : '✗ ${res.stderr}';
      });
    }
    _loadDir(_currentPath);
  }

  Future<void> _pullFile(FileEntry entry) async {
    final adb = context.read<AdbService>();
    await adb.shell('mkdir -p "$_downloadPath"');
    final localDir = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final localSave = '${localDir.path}/${entry.name}';
    setState(() {
      _transferring = true;
      _transferMessage = '下载 ${entry.name}...';
    });
    final remotePath = '$_currentPath/${entry.name}';
    final res = await adb.pull(remotePath, localSave);
    setState(() {
      _transferring = false;
      _transferMessage =
          res.isSuccess ? '✓ 已保存到 $localSave' : '✗ ${res.stderr}';
    });
  }

  Future<void> _deleteEntries(List<String> names) async {
    final adb = context.read<AdbService>();
    for (final name in names) {
      await adb.shell('rm -rf "$_currentPath/$name"');
    }
    _loadDir(_currentPath);
  }

  Future<void> _moveEntries(List<String> names, String destDir) async {
    final adb = context.read<AdbService>();
    for (final name in names) {
      await adb.shell('mv "$_currentPath/$name" "$destDir/"');
    }
    _loadDir(_currentPath);
  }

  Future<void> _copyEntries(List<String> names, String destDir) async {
    final adb = context.read<AdbService>();
    for (final name in names) {
      await adb.shell('cp -r "$_currentPath/$name" "$destDir/"');
    }
    _loadDir(_currentPath);
  }

  void _showMultiSelectActions() {
    final names = _selected.toList();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bg1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _MultiActionSheet(
        selectedCount: names.length,
        onDownload: () async {
          Navigator.pop(context);
          final adb = context.read<AdbService>();
          await adb.shell('mkdir -p "$_downloadPath"');
          for (final name in names) {
            final localDir = await getExternalStorageDirectory() ??
                await getApplicationDocumentsDirectory();
            final localSave = '${localDir.path}/$name';
            setState(() {
              _transferring = true;
              _transferMessage = '下载 $name...';
            });
            final res =
                await adb.pull('$_currentPath/$name', localSave);
            setState(() {
              _transferring = false;
              _transferMessage =
                  res.isSuccess ? '✓ 已下载 $name' : '✗ ${res.stderr}';
            });
          }
          setState(() {
            _multiSelect = false;
            _selected.clear();
          });
        },
        onDelete: () {
          Navigator.pop(context);
          _showDeleteConfirm(names);
        },
        onMove: () async {
          Navigator.pop(context);
          final dest = await _showDeviceDirPicker();
          if (dest != null) await _moveEntries(names, dest);
          setState(() {
            _multiSelect = false;
            _selected.clear();
          });
        },
        onCopy: () async {
          Navigator.pop(context);
          final dest = await _showDeviceDirPicker();
          if (dest != null) await _copyEntries(names, dest);
          setState(() {
            _multiSelect = false;
            _selected.clear();
          });
        },
      ),
    );
  }

  void _showDeleteConfirm(List<String> names) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bg1,
        title: const Text('确认删除',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontFamily: 'SpaceMono',
              fontSize: 15,
            )),
        content: Text('将删除 ${names.length} 个项目，此操作不可撤销。',
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消',
                style: TextStyle(color: AppTheme.textMuted)),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () {
              Navigator.pop(context);
              _deleteEntries(names);
              setState(() {
                _multiSelect = false;
                _selected.clear();
              });
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Future<String?> _showDeviceDirPicker() async {
    final ctrl = TextEditingController(text: _currentPath);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bg1,
        title: const Text('选择目标目录',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontFamily: 'SpaceMono',
              fontSize: 14,
            )),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 12,
            color: AppTheme.textPrimary,
          ),
          decoration: const InputDecoration(
            labelText: '设备路径',
            labelStyle:
                TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消',
                style: TextStyle(color: AppTheme.textMuted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primary),
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  void _showFileActions(FileEntry entry) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bg1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _FileActionSheet(
        entry: entry,
        onInfo: () {
          Navigator.pop(context);
          _showFileInfo(entry);
        },
        onEdit: () {
          Navigator.pop(context);
          _openEditor(entry);
        },
        onDownload: () {
          Navigator.pop(context);
          _pullFile(entry);
        },
      ),
    );
  }

  void _showFileInfo(FileEntry entry) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bg1,
        title: Text(entry.name,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontFamily: 'SpaceMono',
              fontSize: 13,
            )),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoLine('类型', entry.isDirectory ? '目录' : '文件'),
            _InfoLine('路径', '$_currentPath/${entry.name}'),
            _InfoLine('权限', entry.permissions),
            if (!entry.isDirectory) _InfoLine('大小', entry.size),
            _InfoLine('修改时间', entry.date),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭',
                style: TextStyle(color: AppTheme.primary)),
          ),
        ],
      ),
    );
  }

  void _openEditor(FileEntry entry) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FileEditorScreen(
          remotePath: '$_currentPath/${entry.name}',
          fileName: entry.name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return PopScope(
      canPop: _currentPath == '/' || _currentPath.isEmpty,
      onPopInvoked: (didPop) {
        if (!didPop) {
          if (_multiSelect) {
            setState(() {
              _multiSelect = false;
              _selected.clear();
            });
          } else {
            _navigateUp();
          }
        }
      },
      child: Scaffold(
        backgroundColor: AppTheme.bg0,
        body: Column(children: [
          _PathBar(
            currentPath: _currentPath,
            multiSelect: _multiSelect,
            selectedCount: _selected.length,
            onUp: _navigateUp,
            onConfirmMulti: _showMultiSelectActions,
            onCancelMulti: () => setState(() {
              _multiSelect = false;
              _selected.clear();
            }),
          ),
          const Divider(height: 1),
          if (_transferMessage != null)
            _TransferBar(
              transferring: _transferring,
              message: _transferMessage!,
              onClose: () => setState(() => _transferMessage = null),
            ),
          Expanded(
            child: _loading
                ? const CbeeLoader(message: '读取目录...')
                : _entries.isEmpty
                    ? EmptyState(
                        icon: Icons.folder_open_rounded,
                        title: '空目录',
                        message: _currentPath,
                      )
                    : ListView.separated(
                        padding:
                            const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _entries.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, indent: 60),
                        itemBuilder: (ctx, i) {
                          final entry = _entries[i];
                          final isSelected =
                              _selected.contains(entry.name);
                          return _FileRow(
                            entry: entry,
                            multiSelect: _multiSelect,
                            isSelected: isSelected,
                            onTap: () {
                              if (_multiSelect) {
                                setState(() {
                                  if (isSelected) {
                                    _selected.remove(entry.name);
                                  } else {
                                    _selected.add(entry.name);
                                  }
                                });
                              } else if (entry.isDirectory) {
                                _navigate(entry);
                              } else {
                                _showFileActions(entry);
                              }
                            },
                            onLongPress: () {
                              setState(() {
                                _multiSelect = true;
                                _selected.add(entry.name);
                              });
                            },
                          );
                        },
                      ),
          ),
        ]),
        floatingActionButton: _multiSelect
            ? null
            : FloatingActionButton(
                heroTag: 'push',
                onPressed: _pushFile,
                backgroundColor: AppTheme.primary,
                foregroundColor: AppTheme.bg0,
                tooltip: '上传文件到设备',
                child: const Icon(Icons.upload_rounded, size: 22),
              ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  路径栏
// ─────────────────────────────────────────────────────────────
class _PathBar extends StatelessWidget {
  final String currentPath;
  final bool multiSelect;
  final int selectedCount;
  final VoidCallback onUp;
  final VoidCallback onConfirmMulti;
  final VoidCallback onCancelMulti;

  const _PathBar({
    required this.currentPath,
    required this.multiSelect,
    required this.selectedCount,
    required this.onUp,
    required this.onConfirmMulti,
    required this.onCancelMulti,
  });

  @override
  Widget build(BuildContext context) {
    if (multiSelect) {
      return Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: AppTheme.bg1,
        child: Row(children: [
          TextButton(
            onPressed: onCancelMulti,
            child: const Text('取消',
                style: TextStyle(
                  color: AppTheme.textMuted,
                  fontFamily: 'SpaceMono',
                  fontSize: 12,
                )),
          ),
          Expanded(
            child: Center(
              child: Text(
                '已选 $selectedCount 项',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontFamily: 'SpaceMono',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          TextButton(
            onPressed: selectedCount > 0 ? onConfirmMulti : null,
            child: Text(
              '操作',
              style: TextStyle(
                color: selectedCount > 0
                    ? AppTheme.primary
                    : AppTheme.textMuted,
                fontFamily: 'SpaceMono',
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ]),
      );
    }

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: AppTheme.bg1,
      child: Row(children: [
        Expanded(
          child: Text(
            currentPath,
            style: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 12,
              color: AppTheme.textSecondary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: onUp,
          style: TextButton.styleFrom(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text(
            '上一级',
            style: TextStyle(
              fontFamily: 'SpaceMono',
              fontSize: 11,
              color: AppTheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  三点菜单按钮
// ─────────────────────────────────────────────────────────────
class _MoreMenuButton extends StatelessWidget {
  final VoidCallback onRefresh;
  final SortMode currentSort;
  final void Function(SortMode) onSortChanged;

  const _MoreMenuButton({
    required this.onRefresh,
    required this.currentSort,
    required this.onSortChanged,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert_rounded,
          size: 20, color: AppTheme.textMuted),
      color: AppTheme.bg1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onSelected: (v) {
        switch (v) {
          case 'refresh':
            onRefresh();
          case 'sort_name':
            onSortChanged(SortMode.name);
          case 'sort_time':
            onSortChanged(SortMode.time);
          case 'sort_size':
            onSortChanged(SortMode.size);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'refresh',
          child: _MenuRow(icon: Icons.refresh_rounded, label: '刷新列表'),
        ),
        const PopupMenuDivider(),
        _sortItem('sort_name', '名称', SortMode.name),
        _sortItem('sort_time', '时间', SortMode.time),
        _sortItem('sort_size', '大小', SortMode.size),
      ],
    );
  }

  PopupMenuItem<String> _sortItem(
      String value, String label, SortMode mode) {
    final active = currentSort == mode;
    return PopupMenuItem(
      value: value,
      child: _MenuRow(
        icon: active
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_unchecked_rounded,
        label: '按$label排序',
        iconColor: active ? AppTheme.primary : AppTheme.textMuted,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  快捷入口按钮
// ─────────────────────────────────────────────────────────────
class _QuickEntryButton extends StatefulWidget {
  final void Function(String) onNavigate;
  const _QuickEntryButton({required this.onNavigate});
  @override
  State<_QuickEntryButton> createState() => _QuickEntryButtonState();
}

class _QuickEntryButtonState extends State<_QuickEntryButton> {
  List<String> _mountedPaths = [];

  @override
  void initState() {
    super.initState();
    _detectMounts();
  }

  Future<void> _detectMounts() async {
    try {
      final adb = context.read<AdbService>();
      final res =
          await adb.shell('cat /proc/mounts 2>/dev/null');
      final mounts = <String>{};
      for (final line in res.stdout.split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        final mp = parts[1];
        if (mp.startsWith('/storage/') &&
            mp != '/storage/self' &&
            mp != '/storage/emulated' &&
            !mp.contains('emulated')) {
          mounts.add(mp);
        }
      }
      if (mounted) setState(() => _mountedPaths = mounts.toList());
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.bookmark_border_rounded,
          size: 20, color: AppTheme.textMuted),
      color: AppTheme.bg1,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onSelected: widget.onNavigate,
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: '/sdcard',
          child: _MenuRow(
            icon: Icons.phone_android_rounded,
            label: '/sdcard',
            iconColor: AppTheme.primary,
          ),
        ),
        const PopupMenuItem(
          value: '/data',
          child: _MenuRow(
            icon: Icons.storage_rounded,
            label: '/data',
            iconColor: AppTheme.warning,
          ),
        ),
        if (_mountedPaths.isNotEmpty) const PopupMenuDivider(),
        ..._mountedPaths.map((p) => PopupMenuItem(
              value: p,
              child: _MenuRow(
                icon: Icons.sd_card_rounded,
                label: p,
                iconColor: AppTheme.success,
              ),
            )),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  传输状态条
// ─────────────────────────────────────────────────────────────
class _TransferBar extends StatelessWidget {
  final bool transferring;
  final String message;
  final VoidCallback onClose;

  const _TransferBar({
    required this.transferring,
    required this.message,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.bg1,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.bg3),
      ),
      child: Row(children: [
        if (transferring)
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor:
                  AlwaysStoppedAnimation(AppTheme.primary),
            ),
          )
        else
          Icon(
            message.startsWith('✓')
                ? Icons.check_circle_outline_rounded
                : Icons.error_outline_rounded,
            size: 14,
            color: message.startsWith('✓')
                ? AppTheme.success
                : AppTheme.danger,
          ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11,
              color: AppTheme.textSecondary,
            ),
          ),
        ),
        if (!transferring)
          GestureDetector(
            onTap: onClose,
            child: const Icon(Icons.close_rounded,
                size: 14, color: AppTheme.textMuted),
          ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  文件行
// ─────────────────────────────────────────────────────────────
class _FileRow extends StatelessWidget {
  final FileEntry entry;
  final bool multiSelect;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _FileRow({
    required this.entry,
    required this.multiSelect,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
  });

  IconData get _icon {
    if (entry.isDirectory) return Icons.folder_rounded;
    final ext = entry.name.split('.').last.toLowerCase();
    return switch (ext) {
      'apk' => Icons.android_rounded,
      'zip' || 'tar' || 'gz' || 'rar' => Icons.archive_rounded,
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' =>
        Icons.image_rounded,
      'mp4' || 'mkv' || 'avi' => Icons.movie_rounded,
      'mp3' || 'aac' || 'flac' || 'ogg' => Icons.audio_file_rounded,
      'pdf' => Icons.picture_as_pdf_rounded,
      'txt' ||
      'log' ||
      'xml' ||
      'json' ||
      'yaml' ||
      'sh' =>
        Icons.description_rounded,
      _ => Icons.insert_drive_file_rounded,
    };
  }

  Color get _iconColor {
    if (entry.isDirectory) return AppTheme.warning;
    final ext = entry.name.split('.').last.toLowerCase();
    return switch (ext) {
      'apk' => AppTheme.success,
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' =>
        AppTheme.secondary,
      'mp4' || 'mkv' || 'avi' => const Color(0xFF9B59B6),
      'pdf' => AppTheme.danger,
      _ => AppTheme.textMuted,
    };
  }

  String _formatSize(String raw) {
    final n = int.tryParse(raw);
    if (n == null) return raw;
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: _iconColor.withOpacity(isSelected ? 0.25 : 0.1),
          borderRadius: BorderRadius.circular(8),
          border: isSelected
              ? Border.all(color: AppTheme.primary, width: 1.5)
              : null,
        ),
        child: Icon(_icon, size: 18, color: _iconColor),
      ),
      title: Text(
        entry.name,
        style: const TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 13,
          color: AppTheme.textPrimary,
        ),
      ),
      subtitle: Text(
        '${entry.permissions}  '
        '${entry.isDirectory ? '' : _formatSize(entry.size)}  '
        '${entry.date}',
        style: const TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 10,
          color: AppTheme.textMuted,
        ),
      ),
      trailing: multiSelect
          ? Checkbox(
              value: isSelected,
              onChanged: (_) => onTap(),
              activeColor: AppTheme.primary,
              side: const BorderSide(color: AppTheme.textMuted),
            )
          : entry.isDirectory
              ? const Icon(Icons.chevron_right_rounded,
                  size: 16, color: AppTheme.textMuted)
              : null,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  文件操作 BottomSheet
// ─────────────────────────────────────────────────────────────
class _FileActionSheet extends StatelessWidget {
  final FileEntry entry;
  final VoidCallback onInfo;
  final VoidCallback onEdit;
  final VoidCallback onDownload;

  const _FileActionSheet({
    required this.entry,
    required this.onInfo,
    required this.onEdit,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(children: [
              const Icon(Icons.insert_drive_file_rounded,
                  size: 18, color: AppTheme.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.name,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 13,
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ]),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.info_outline_rounded,
                size: 20, color: AppTheme.secondary),
            title: const Text('信息',
                style: TextStyle(
                    fontSize: 14, color: AppTheme.textPrimary)),
            onTap: onInfo,
          ),
          ListTile(
            leading: const Icon(Icons.edit_note_rounded,
                size: 20, color: AppTheme.primary),
            title: const Text('编辑',
                style: TextStyle(
                    fontSize: 14, color: AppTheme.textPrimary)),
            onTap: onEdit,
          ),
          ListTile(
            leading: const Icon(Icons.download_rounded,
                size: 20, color: AppTheme.success),
            title: const Text('下载',
                style: TextStyle(
                    fontSize: 14, color: AppTheme.textPrimary)),
            onTap: onDownload,
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  多选操作 BottomSheet
// ─────────────────────────────────────────────────────────────
class _MultiActionSheet extends StatelessWidget {
  final int selectedCount;
  final VoidCallback onDownload;
  final VoidCallback onDelete;
  final VoidCallback onMove;
  final VoidCallback onCopy;

  const _MultiActionSheet({
    required this.selectedCount,
    required this.onDownload,
    required this.onDelete,
    required this.onMove,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              '对 $selectedCount 个项目执行操作',
              style: const TextStyle(
                fontFamily: 'SpaceMono',
                fontSize: 13,
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.download_rounded,
                size: 20, color: AppTheme.success),
            title: const Text('下载',
                style: TextStyle(
                    fontSize: 14, color: AppTheme.textPrimary)),
            onTap: onDownload,
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_move_outline_rounded,
                size: 20, color: AppTheme.primary),
            title: const Text('移动',
                style: TextStyle(
                    fontSize: 14, color: AppTheme.textPrimary)),
            onTap: onMove,
          ),
          ListTile(
            leading: const Icon(Icons.copy_rounded,
                size: 20, color: AppTheme.secondary),
            title: const Text('复制',
                style: TextStyle(
                    fontSize: 14, color: AppTheme.textPrimary)),
            onTap: onCopy,
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded,
                size: 20, color: AppTheme.danger),
            title: const Text('删除',
                style: TextStyle(
                    fontSize: 14, color: AppTheme.danger)),
            onTap: onDelete,
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  内置文件编辑器
// ─────────────────────────────────────────────────────────────
class _FileEditorScreen extends StatefulWidget {
  final String remotePath;
  final String fileName;
  const _FileEditorScreen(
      {required this.remotePath, required this.fileName});
  @override
  State<_FileEditorScreen> createState() => _FileEditorScreenState();
}

class _FileEditorScreenState extends State<_FileEditorScreen> {
  final _ctrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFile();
  }

  Future<void> _loadFile() async {
    final adb = context.read<AdbService>();
    final res =
        await adb.shell('cat "${widget.remotePath}" 2>&1');
    setState(() {
      _loading = false;
      if (res.exitCode != 0 && res.stderr.isNotEmpty) {
        _error = res.stderr;
      } else {
        _ctrl.text = res.stdout;
      }
    });
  }

  Future<void> _saveFile() async {
    setState(() => _saving = true);
    final adb = context.read<AdbService>();
    final encoded = base64.encode(utf8.encode(_ctrl.text));
    final res = await adb.shell(
        'echo "$encoded" | base64 -d > "${widget.remotePath}" 2>&1');
    setState(() => _saving = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            res.exitCode == 0 ? '✓ 已保存' : '✗ ${res.stderr}'),
        backgroundColor:
            res.exitCode == 0 ? AppTheme.success : AppTheme.danger,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg0,
      appBar: AppBar(
        title: Text(widget.fileName,
            style:
                const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 14)),
        actions: [
          if (!_loading && _error == null)
            _saving
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.save_rounded),
                    onPressed: _saveFile,
                    tooltip: '保存到设备',
                  ),
        ],
      ),
      body: _loading
          ? const CbeeLoader(message: '读取文件...')
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: AppTheme.danger,
                        fontFamily: 'JetBrainsMono',
                        fontSize: 12,
                      ),
                    ),
                  ),
                )
              : TextField(
                  controller: _ctrl,
                  maxLines: null,
                  expands: true,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12,
                    color: AppTheme.textPrimary,
                  ),
                  decoration: const InputDecoration(
                    contentPadding: EdgeInsets.all(16),
                    border: InputBorder.none,
                  ),
                ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────
//  小工具
// ─────────────────────────────────────────────────────────────
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color iconColor;

  const _MenuRow({
    required this.icon,
    required this.label,
    this.iconColor = AppTheme.textSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 16, color: iconColor),
      const SizedBox(width: 10),
      Text(
        label,
        style: const TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 13,
          color: AppTheme.textPrimary,
        ),
      ),
    ]);
  }
}

class _InfoLine extends StatelessWidget {
  final String label;
  final String value;
  const _InfoLine(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: 'SpaceMono',
                fontSize: 11,
                color: AppTheme.textMuted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 11,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
