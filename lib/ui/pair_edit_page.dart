import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../util/paths.dart';

class PairEditPage extends StatefulWidget {
  const PairEditPage({super.key, this.pair});
  final Pair? pair;

  @override
  State<PairEditPage> createState() => _PairEditPageState();
}

class _PairEditPageState extends State<PairEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _local;
  late final TextEditingController _remote;
  bool _saving = false;
  bool _hasPermission = true;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.pair?.name ?? '');
    _local = TextEditingController(
        text: widget.pair?.localPath ?? AppState.defaultLocalRoot());
    _remote = TextEditingController(text: widget.pair?.remotePath ?? '');
    AppState.hasAllFilesAccess().then((v) {
      if (mounted) setState(() => _hasPermission = v);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _local.dispose();
    _remote.dispose();
    super.dispose();
  }

  Future<void> _pickLocal() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择要同步的本地文件夹',
    );
    if (dir != null) {
      setState(() => _local.text = dir);
    }
  }

  Future<void> _pickRemote() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => RemoteBrowsePage(initial: _remote.text),
      ),
    );
    if (result != null) setState(() => _remote.text = result);
  }

  Future<void> _save() async {
    final local = _local.text.trim();
    final remote = _remote.text.trim();
    if (local.isEmpty) {
      _snack('请选择本地文件夹');
      return;
    }
    if (!local.startsWith('/')) {
      _snack('本地路径必须是绝对路径');
      return;
    }
    final state = context.read<AppState>();
    // Refuse overlapping local roots: they would fight over the same files.
    for (final other in state.pairs) {
      if (other.id == widget.pair?.id) continue;
      if (isSameOrUnder(local, other.localPath) ||
          isSameOrUnder(other.localPath, local)) {
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('目录重叠'),
            content: Text('该本地目录与「${other.name}」的本地目录重叠，'
                '同时启用两者可能产生冲突。仍然保存？'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('仍然保存')),
            ],
          ),
        );
        if (go != true) return;
        break;
      }
    }

    setState(() => _saving = true);
    try {
      if (widget.pair == null) {
        await state.addPair(
          name: _name.text.isEmpty ? _local.text.split('/').last : _name.text,
          localPath: local,
          remotePath: remote,
        );
      } else {
        await state.updatePair(widget.pair!.copyWith(
          name: _name.text.trim().isEmpty
              ? widget.pair!.name
              : _name.text.trim(),
          localPath: local,
          remotePath: AppState.normalizeRemote(remote),
        ));
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      _snack('保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editing = widget.pair != null;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? '编辑同步' : '添加同步')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '名称（可选）',
              hintText: '例如：笔记',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _local,
            decoration: InputDecoration(
              labelText: '本地文件夹',
              hintText: '/storage/emulated/0/Notes',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: '选择文件夹',
                icon: const Icon(Icons.folder_open),
                onPressed: _pickLocal,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (!_hasPermission)
            Card(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.warning_amber),
                title: const Text('需要「所有文件访问权限」才能同步共享存储中的文件夹'),
                subtitle: const Text('授权后请返回本页重试'),
                trailing: TextButton(
                  onPressed: () async {
                    await AppState.requestAllFilesAccess();
                    final v = await AppState.hasAllFilesAccess();
                    if (mounted) setState(() => _hasPermission = v);
                  },
                  child: const Text('授权'),
                ),
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _remote,
            decoration: InputDecoration(
              labelText: '远程目录',
              hintText: '留空表示账号根目录',
              prefixText: '/',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: '浏览远程目录',
                icon: const Icon(Icons.cloud_queue),
                onPressed: _pickRemote,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('同步规则', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text(
                    '• 双向同步：本地与远程的修改会互相传播\n'
                    '• 删除也会双向同步（远程删除可从 Nextcloud 回收站恢复）\n'
                    '• 两边同时修改时自动保留两份并提示\n'
                    '• 无法自动判断的情况会进入「冲突」列表等待你选择\n'
                    '• 隐藏文件、符号链接、大小写敏感的文件名都会同步',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check),
            label: Text(editing ? '保存' : '添加'),
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16)),
          ),
          if (Directory(_local.text).existsSync())
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text('本地目录已存在，将直接同步其中的内容。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ),
        ],
      ),
    );
  }
}

class RemoteBrowsePage extends StatefulWidget {
  const RemoteBrowsePage({super.key, this.initial = ''});
  final String initial;

  @override
  State<RemoteBrowsePage> createState() => _RemoteBrowsePageState();
}

class _RemoteBrowsePageState extends State<RemoteBrowsePage> {
  late String _path;
  List<RemoteEntry> _entries = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _path = normalizeRel(widget.initial);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!mounted) return;
      final list = await context.read<AppState>().client.list(_path);
      list.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _entries = list.where((e) => e.isDir).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _enter(String path) {
    setState(() => _path = path);
    _load();
  }

  void _up() {
    if (_path.isEmpty) return;
    _enter(parentOf(_path));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_path.isEmpty ? '/（根目录）' : '/$_path'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_upward),
          tooltip: '上一级',
          onPressed: _path.isEmpty ? null : _up,
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).pop(_path),
        icon: const Icon(Icons.check),
        label: const Text('选择此目录'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('无法读取远程目录：\n$_error',
                        textAlign: TextAlign.center),
                  ),
                )
              : ListView(
                  children: [
                    if (_entries.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: Text('此目录下没有子目录')),
                      ),
                    for (final e in _entries)
                      ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(baseName(e.path)),
                        onTap: () => _enter(e.path),
                      ),
                  ],
                ),
    );
  }
}
