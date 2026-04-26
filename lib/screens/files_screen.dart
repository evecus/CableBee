import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../services/adb_service.dart';
import '../utils/theme.dart';
import '../widgets/common.dart';
import '../widgets/local_file_picker.dart';

class FilesScreen extends StatefulWidget {
  final void Function(List<Widget> actions)? onActionsChanged;
  const FilesScreen({super.key, this.onActionsChanged});
  @override
  State<FilesScreen> createState() => FilesScreenState();
}

class FilesScreenState extends State<FilesScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  void refreshActions() => _pushActions();

  String _currentPath = '/sdcard';
  List<FileEntry> _entries = [];
  final List<String> _breadcrumbs = ['/sdcard'];
  bool _loading = false;
  bool _transferring = false;
  String? _transferMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDir(_currentPath);
      _pushActions();
    });
  }

  void _pushActions() {
    widget.onActionsChanged?.call([
      IconButton(
        icon: const Icon(Icons.refresh_rounded, size: 20),
        onPressed: () => _loadDir(_currentPath),
        color: AppTheme.textMuted,
      ),
    ]);
  }

  Future<void> _loadDir(String path) async {
    final adb = context.read<AdbService>();
    setState(() { _loading = true; });
    final entries = await adb.listFiles(path);
    entries.sort((a, b) {
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;
      return a.name.compareTo(b.name);
    });
    setState(() {
      _currentPath = path;
      _entries = entries;
      _loading = false;
    });
  }

  void _navigate(FileEntry entry) {
    if (!entry.isDirectory) return;
    final newPath = '$_currentPath/${entry.name}'.replaceAll('//', '/');
    setState(() => _breadcrumbs.add(newPath));
    _loadDir(newPath);
  }

  void _navigateTo(String path) {
    final idx = _breadcrumbs.indexOf(path);
    if (idx >= 0) {
      setState(() => _breadcrumbs.removeRange(idx + 1, _breadcrumbs.length));
    }
    _loadDir(path);
  }

  bool _navigateUp() {
    if (_breadcrumbs.length <= 1) return false;
    setState(() => _breadcrumbs.removeLast());
    _loadDir(_breadcrumbs.last);
    return true;
  }

  Future<void> _pushFile() async {
    final results = await showLocalFilePicker(
      context,
      allowMultiple: false,
      allowFolders: false,
    );
    if (results == null || results.isEmpty) return;
    final localPath = results.first;
    final fileName = localPath.split('/').last;
    final remotePath = '$_currentPath/$fileName';

    setState(() {
      _transferring = true;
      _transferMessage = 'Pushing $fileName...';
    });
    final res = await context.read<AdbService>().push(localPath, remotePath);
    setState(() {
      _transferring = false;
      _transferMessage = res.isSuccess ? '✓ Pushed $fileName' : '✗ ${res.stderr}';
    });
    if (res.isSuccess) _loadDir(_currentPath);
  }

  Future<void> _pullFile(FileEntry entry) async {
    final dir = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final savePath = '${dir.path}/${entry.name}';

    setState(() {
      _transferring = true;
      _transferMessage = 'Pulling ${entry.name}...';
    });
    final remotePath = '$_currentPath/${entry.name}';
    final res = await context.read<AdbService>().pull(remotePath, savePath);
    setState(() {
      _transferring = false;
      _transferMessage = res.isSuccess
          ? '✓ Saved to $savePath'
          : '✗ ${res.stderr}';
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final adb = context.watch<AdbService>();

    return PopScope(
      canPop: _breadcrumbs.length <= 1,
      onPopInvoked: (didPop) {
        if (!didPop) _navigateUp();
      },
      child: Scaffold(
        backgroundColor: AppTheme.bg0,
        body: Column(children: [
          // Breadcrumb bar (replaces AppBar bottom)
          _BreadcrumbBar(
            crumbs: _breadcrumbs,
            onTap: _navigateTo,
          ),
          const Divider(height: 1),
          // Transfer status bar
          if (_transferMessage != null)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.bg1,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.bg3),
              ),
              child: Row(children: [
                if (_transferring)
                  const SizedBox(
                    width: 12, height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      valueColor: AlwaysStoppedAnimation(AppTheme.primary),
                    ),
                  )
                else
                  Icon(
                    _transferMessage!.startsWith('✓')
                        ? Icons.check_circle_outline_rounded
                        : Icons.error_outline_rounded,
                    size: 14,
                    color: _transferMessage!.startsWith('✓')
                        ? AppTheme.success : AppTheme.danger,
                  ),
                const SizedBox(width: 8),
                Expanded(child: Text(_transferMessage!, style: const TextStyle(
                  fontFamily: 'JetBrainsMono', fontSize: 11,
                  color: AppTheme.textSecondary,
                ))),
                if (!_transferring)
                  GestureDetector(
                    onTap: () => setState(() => _transferMessage = null),
                    child: const Icon(Icons.close_rounded, size: 14, color: AppTheme.textMuted),
                  ),
              ]),
            ),

          // File list
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
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _entries.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, indent: 60),
                        itemBuilder: (ctx, i) {
                          final entry = _entries[i];
                          return _FileRow(
                            entry: entry,
                            onTap: entry.isDirectory
                                ? () => _navigate(entry)
                                : null,
                            onPull: entry.isDirectory
                                ? null
                                : () => _pullFile(entry),
                          );
                        },
                      ),
          ),
        ]),
        floatingActionButton: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FloatingActionButton.small(
              heroTag: 'push',
              onPressed: _pushFile,
              backgroundColor: AppTheme.primary,
              foregroundColor: AppTheme.bg0,
              tooltip: '推送文件到设备',
              child: const Icon(Icons.upload_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Breadcrumb bar ────────────────────────────────────────────────────────────

class _BreadcrumbBar extends StatelessWidget {
  final List<String> crumbs;
  final void Function(String) onTap;

  const _BreadcrumbBar({required this.crumbs, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: crumbs.asMap().entries.expand((e) {
          final isLast = e.key == crumbs.length - 1;
          final label = e.key == 0
              ? e.value
              : e.value.split('/').last;
          return [
            GestureDetector(
              onTap: isLast ? null : () => onTap(e.value),
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono', fontSize: 12,
                  color: isLast ? AppTheme.textPrimary : AppTheme.textMuted,
                  fontWeight: isLast ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (!isLast)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.chevron_right_rounded,
                  size: 14, color: AppTheme.textMuted),
              ),
          ];
        }).toList(),
      ),
    );
  }
}

// ── File Row ──────────────────────────────────────────────────────────────────

class _FileRow extends StatelessWidget {
  final FileEntry entry;
  final VoidCallback? onTap;
  final VoidCallback? onPull;

  const _FileRow({required this.entry, this.onTap, this.onPull});

  IconData get _icon {
    if (entry.isDirectory) return Icons.folder_rounded;
    final ext = entry.name.split('.').last.toLowerCase();
    return switch (ext) {
      'apk'  => Icons.android_rounded,
      'zip' || 'tar' || 'gz' => Icons.archive_rounded,
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' => Icons.image_rounded,
      'mp4' || 'mkv' || 'avi' => Icons.movie_rounded,
      'mp3' || 'aac' || 'flac' => Icons.audio_file_rounded,
      'pdf'  => Icons.picture_as_pdf_rounded,
      'txt' || 'log' || 'xml' || 'json' => Icons.description_rounded,
      _ => Icons.insert_drive_file_rounded,
    };
  }

  Color get _iconColor {
    if (entry.isDirectory) return AppTheme.warning;
    final ext = entry.name.split('.').last.toLowerCase();
    return switch (ext) {
      'apk'  => AppTheme.success,
      'jpg' || 'jpeg' || 'png' || 'gif' => AppTheme.secondary,
      'mp4' || 'mkv' => const Color(0xFF9B59B6),
      'pdf'  => AppTheme.danger,
      _ => AppTheme.textMuted,
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      leading: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: _iconColor.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(_icon, size: 18, color: _iconColor),
      ),
      title: Text(entry.name, style: const TextStyle(
        fontFamily: 'JetBrainsMono', fontSize: 13,
        color: AppTheme.textPrimary,
      )),
      subtitle: Text(
        '${entry.permissions}  ${entry.isDirectory ? '' : entry.size}  ${entry.date}',
        style: const TextStyle(
          fontFamily: 'JetBrainsMono', fontSize: 10,
          color: AppTheme.textMuted,
        ),
      ),
      trailing: onPull != null
          ? IconButton(
              icon: const Icon(Icons.download_rounded, size: 18, color: AppTheme.primary),
              onPressed: onPull,
              tooltip: '拉取到本机',
            )
          : entry.isDirectory
              ? const Icon(Icons.chevron_right_rounded, size: 16, color: AppTheme.textMuted)
              : null,
      onTap: onTap,
    );
  }
}
