import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../sync/notifications.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _deviceName;
  String _version = '';
  bool _busy = false;

  static const _intervals = [15, 30, 60, 120, 240, 720];

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _deviceName = TextEditingController(text: state.settings.deviceName);
    state.serverVersion().then((v) {
      if (mounted) setState(() => _version = v);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    final state = context.read<AppState>();
    await state.saveSettings(
        state.settings.copyWith(deviceName: _deviceName.text.trim().isEmpty
            ? 'Android'
            : _deviceName.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final s = state.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          _section('账号', theme),
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: Text(state.account?.server ?? ''),
            subtitle: Text(state.account == null
                ? '未登录'
                : '${state.account!.username}'
                    '${_version.isEmpty ? '' : ' · Nextcloud $_version'}'),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('退出登录'),
            subtitle: const Text('清除本机保存的应用密码'),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('退出登录'),
                  content: const Text('将停止后台同步并删除本机保存的凭据。'
                      '同步配对与已同步的文件会保留。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('退出')),
                  ],
                ),
              );
              if (ok == true && context.mounted) {
                final navigator = Navigator.of(context);
                await context.read<AppState>().logout();
                navigator.pop();
              }
            },
          ),
          const Divider(),
          _section('同步', theme),
          ListTile(
            leading: const Icon(Icons.phone_android),
            title: const Text('设备名称'),
            subtitle: const Text('用于命名冲突副本'),
            trailing: SizedBox(
              width: 140,
              child: TextField(
                controller: _deviceName,
                textAlign: TextAlign.end,
                decoration: const InputDecoration(isDense: true),
                onSubmitted: (_) => _saveName(),
                onTapOutside: (_) => _saveName(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text('后台同步间隔'),
            subtitle: const Text('Android 限制最短 15 分钟，系统可能延后执行'),
            trailing: DropdownButton<int>(
              value: _intervals.contains(s.intervalMinutes)
                  ? s.intervalMinutes
                  : 15,
              items: [
                for (final m in _intervals)
                  DropdownMenuItem(
                    value: m,
                    child: Text(m < 60 ? '$m 分钟' : '${m ~/ 60} 小时'),
                  ),
              ],
              onChanged: (v) async {
                if (v == null) return;
                await state.saveSettings(s.copyWith(intervalMinutes: v));
              },
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.wifi),
            title: const Text('仅 Wi-Fi 下同步'),
            subtitle: const Text('移动网络下会跳过自动同步'),
            value: s.wifiOnly,
            onChanged: (v) => state.saveSettings(s.copyWith(wifiOnly: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: const Text('同步完成通知'),
            subtitle: const Text('有改动、冲突或失败时通知'),
            value: s.notify,
            onChanged: (v) async {
              await state.saveSettings(s.copyWith(notify: v));
              if (v) {
                await Notifications.init(requestPermission: true);
                await Notifications.show('通知已开启', '同步结果会在这里提醒');
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('立即同步全部'),
            trailing: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_right),
            onTap: _busy
                ? null
                : () async {
                    final messenger = ScaffoldMessenger.of(context);
                    setState(() => _busy = true);
                    await state.syncAll();
                    if (!mounted) return;
                    setState(() => _busy = false);
                    messenger.showSnackBar(
                        const SnackBar(content: Text('同步完成')));
                  },
          ),
          const Divider(),
          _section('备份与恢复', theme),
          ListTile(
            leading: const Icon(Icons.upload_file_outlined),
            title: const Text('导出配置（含应用密码）'),
            subtitle: const Text('JSON 文件，换机/重装后可直接恢复，注意妥善保管'),
            onTap: () => _export(includeCredentials: true),
          ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('导出配置（不含密码）'),
            subtitle: const Text('导入后需要重新登录，适合分享配置结构'),
            onTap: () => _export(includeCredentials: false),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('导入配置'),
            subtitle: const Text('从 JSON 文件恢复账号、设置与同步配对'),
            onTap: _import,
          ),
          const Divider(),
          _section('关于', theme),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Nextcloud Sync for Android'),
            subtitle: Text('版本 1.0.0 · 双向目录同步\n'
                '仅支持 Android，凭据保存在系统 Keystore 加密存储中'),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _export({required bool includeCredentials}) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    if (includeCredentials) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导出包含密码'),
          content: const Text('导出的 JSON 里会包含 Nextcloud 应用密码（明文）。'
              '请把文件保存到安全的位置，不要分享给他人。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('继续导出')),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      final json = await state.exportConfig(
          includeCredentials: includeCredentials);
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '保存配置',
        fileName: 'ncsync-config${includeCredentials ? '' : '-nopass'}.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: utf8.encode(json),
      );
      if (path == null) return;
      messenger.showSnackBar(SnackBar(content: Text('已导出到 $path')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  Future<void> _import() async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    String raw;
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: '选择配置文件',
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      final file = result?.files.single;
      if (file == null) return;
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) throw '无法读取文件';
      raw = utf8.decode(bytes);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('读取失败：$e')));
      return;
    }

    if (!mounted) return;
    final mode = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入方式'),
        content: const Text('「合并」保留现有配对并跳过重复项；'
            '「覆盖」会先删除现有配对（不会删除文件）。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'merge'),
              child: const Text('合并')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'replace'),
              child: const Text('覆盖')),
        ],
      ),
    );
    if (mode == null) return;
    try {
      final summary =
          await state.importConfig(raw, replace: mode == 'replace');
      messenger.showSnackBar(SnackBar(content: Text('导入完成：${summary.message}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  Widget _section(String title, ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(title,
            style: theme.textTheme.labelLarge
                ?.copyWith(color: theme.colorScheme.primary)),
      );
}
