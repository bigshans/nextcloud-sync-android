import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../sync/engine.dart';
import '../util/format.dart';

class ConflictsPage extends StatefulWidget {
  const ConflictsPage({super.key});

  @override
  State<ConflictsPage> createState() => _ConflictsPageState();
}

class _ConflictsPageState extends State<ConflictsPage> {
  List<ConflictRow> _conflicts = [];
  Map<int, Pair> _pairs = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final conflicts = await state.db.allPendingConflicts();
    final pairs = {for (final p in state.pairs) p.id!: p};
    if (!mounted) return;
    setState(() {
      _conflicts = conflicts;
      _pairs = pairs;
      _loading = false;
    });
  }

  Future<void> _resolve(ConflictRow c, ConflictChoice choice) async {
    final state = context.read<AppState>();
    setState(() => _loading = true);
    try {
      await state.resolveConflict(c, choice);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已处理 /${c.path}')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('处理失败：$e')));
    }
  }

  String _kindLabel(String kind) => switch (kind) {
        'manual' => '需要选择',
        'auto-both' => '已自动保留两份',
        'case' => '大小写冲突',
        _ => kind,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('冲突')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _conflicts.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_outline,
                          size: 56, color: theme.colorScheme.primary),
                      const SizedBox(height: 12),
                      const Text('没有待处理的冲突'),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _conflicts.length,
                    itemBuilder: (_, i) {
                      final c = _conflicts[i];
                      final pair = _pairs[c.pairId];
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Chip(
                                    label: Text(_kindLabel(c.kind)),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(pair?.name ?? '已删除的配对',
                                        style: theme.textTheme.bodySmall),
                                  ),
                                  Text(formatTime(c.createdAt),
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                              color:
                                                  theme.colorScheme.outline)),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text('/${c.path}',
                                  style: theme.textTheme.bodyMedium),
                              if (c.detail != null) ...[
                                const SizedBox(height: 4),
                                Text(c.detail!,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.outline)),
                              ],
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                children: [
                                  FilledButton.tonal(
                                    onPressed: () => _resolve(
                                        c, ConflictChoice.keepLocal),
                                    child: const Text('保留本地'),
                                  ),
                                  FilledButton.tonal(
                                    onPressed: () => _resolve(
                                        c, ConflictChoice.keepRemote),
                                    child: const Text('保留远程'),
                                  ),
                                  FilledButton.tonal(
                                    onPressed: () =>
                                        _resolve(c, ConflictChoice.keepBoth),
                                    child: const Text('两份都保留'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
