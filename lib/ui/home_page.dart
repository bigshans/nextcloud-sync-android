import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../util/format.dart';
import 'conflicts_page.dart';
import 'logs_page.dart';
import 'pair_edit_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _permissionChecked = false;
  bool _hasPermission = true;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    final ok = await AppState.hasAllFilesAccess();
    if (!mounted) return;
    setState(() {
      _hasPermission = ok;
      _permissionChecked = true;
    });
  }

  Future<void> _syncAll() async {
    final state = context.read<AppState>();
    await state.syncAll();
    if (!mounted) return;
    final r = state.lastReport;
    if (r != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${r.pairName}：${r.summary}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nextcloud 同步'),
        actions: [
          Badge(
            isLabelVisible: state.pendingConflicts > 0,
            label: Text('${state.pendingConflicts}'),
            child: IconButton(
              tooltip: '冲突',
              icon: const Icon(Icons.call_split),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ConflictsPage())),
            ),
          ),
          IconButton(
            tooltip: '立即同步',
            onPressed: state.syncing ? null : _syncAll,
            icon: state.syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'logs':
                  await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LogsPage()));
                  break;
                case 'settings':
                  await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsPage()));
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'logs', child: Text('同步日志')),
              PopupMenuItem(value: 'settings', child: Text('设置')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const PairEditPage()));
          await _checkPermission();
        },
        icon: const Icon(Icons.add),
        label: const Text('添加同步'),
      ),
      body: Column(
        children: [
          if (_permissionChecked && !_hasPermission)
            MaterialBanner(
              leading: const Icon(Icons.folder_off_outlined),
              content: const Text(
                  '尚未授予「所有文件访问权限」，只能同步应用专属目录。'
                  '若要同步 /storage/emulated/0 下的文件夹，请授予权限。'),
              actions: [
                TextButton(
                  onPressed: () async {
                    await AppState.requestAllFilesAccess();
                    await _checkPermission();
                  },
                  child: const Text('去授权'),
                ),
              ],
            ),
          if (state.progress != null)
            _ProgressCard(
              progress: state.progress!,
              syncing: state.syncing,
              paused: state.paused,
              onPause: state.pauseSync,
              onResume: () => state.resumeSync(),
              onDismiss: state.dismissPaused,
            ),
          Expanded(
            child: state.pairs.isEmpty
                ? _EmptyState(onAdd: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const PairEditPage()));
                    await _checkPermission();
                  })
                : RefreshIndicator(
                    onRefresh: _syncAll,
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                      itemCount: state.pairs.length,
                      itemBuilder: (_, i) {
                        final pair = state.pairs[i];
                        return _PairCard(
                          pair: pair,
                          onSync: () async {
                            await state.syncPair(pair);
                            if (!context.mounted) return;
                            final r = state.lastReport;
                            if (r != null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text(
                                          '${r.pairName}：${r.summary}')));
                            }
                          },
                          onEdit: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) =>
                                      PairEditPage(pair: pair))),
                          onDelete: () => _confirmDelete(pair),
                          onToggle: (v) =>
                              state.updatePair(pair.copyWith(enabled: v)),
                        );
                      },
                    ),
                  ),
          ),
          if (state.lastError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(state.lastError!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(Pair pair) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除同步配对'),
        content: Text('确定删除「${pair.name}」？\n'
            '只会删除配对配置，不会删除本地或远程的文件。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<AppState>().deletePair(pair.id!);
    }
  }
}

class _PairCard extends StatelessWidget {
  const _PairCard({
    required this.pair,
    required this.onSync,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  final Pair pair;
  final VoidCallback onSync;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final syncing = context.select<AppState, bool>((s) => s.syncing);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(pair.name,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  tooltip: '立即同步',
                  icon: const Icon(Icons.sync),
                  onPressed: syncing ? null : onSync,
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'edit') onEdit();
                    if (v == 'delete') onDelete();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
                Switch(value: pair.enabled, onChanged: onToggle),
              ],
            ),
            const SizedBox(height: 4),
            _pathRow(Icons.phone_android, pair.localPath, theme),
            const SizedBox(height: 2),
            _pathRow(Icons.cloud_outlined,
                pair.remotePath.isEmpty ? '/（账号根目录）' : '/${pair.remotePath}',
                theme),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  pair.lastResult == null
                      ? Icons.schedule
                      : (pair.lastResult!.startsWith('失败') ||
                              pair.lastResult!.contains('错误'))
                          ? Icons.error_outline
                          : Icons.check_circle_outline,
                  size: 14,
                  color: pair.lastResult == null
                      ? theme.colorScheme.outline
                      : (pair.lastResult!.startsWith('失败') ||
                              pair.lastResult!.contains('错误'))
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${formatTime(pair.lastSyncAt)} · ${pair.lastResult ?? "尚未同步"}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _pathRow(IconData icon, String text, ThemeData theme) => Row(
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.outline),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall),
          ),
        ],
      );
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.progress,
    required this.syncing,
    required this.paused,
    required this.onPause,
    required this.onResume,
    required this.onDismiss,
  });

  final SyncProgress progress;
  final bool syncing;
  final bool paused;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(progress.pairName ?? '',
                    style: theme.textTheme.titleSmall),
                const Spacer(),
                Text(progress.phase,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
                const SizedBox(width: 8),
                if (syncing && !paused)
                  TextButton.icon(
                    onPressed: onPause,
                    icon: const Icon(Icons.pause, size: 18),
                    label: const Text('暂停'),
                  )
                else if (paused) ...[
                  TextButton.icon(
                    onPressed: onResume,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('继续'),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: onDismiss,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: progress.fraction,
              minHeight: 6,
            ),
            const SizedBox(height: 8),
            Text(
              progress.current ??
                  (progress.total > 0
                      ? '${progress.done}/${progress.total}'
                      : '已处理 ${progress.done} 项'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_outlined,
                size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text('还没有同步目录',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('添加一组「本地文件夹 ↔ Nextcloud 目录」即可开始双向同步',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('添加同步'),
            ),
          ],
        ),
      ),
    );
  }
}
