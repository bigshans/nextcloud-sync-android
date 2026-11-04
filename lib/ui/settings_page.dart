import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';

import '../nextcloud/http_clients.dart';
import '../state/app_state.dart';
import '../util/format.dart';
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
            isThreeLine: true,
            title: Text(state.account?.server ?? ''),
            subtitle: Text(state.account == null
                ? '未登录'
                : '${state.account!.username}'
                    '${_version.isEmpty ? '' : ' · Nextcloud $_version'}'
                    '\n传输：${HttpClients.cronetAvailable ? 'HTTP/2 (Cronet)' : 'HTTP/1.1'}'),
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
          SwitchListTile(
            secondary: const Icon(Icons.schedule_send_outlined),
            title: const Text('后台定时同步'),
            subtitle: const Text('关闭后只在手动点击时同步（不会取消正在进行的同步）'),
            value: s.autoSync,
            onChanged: (v) => state.saveSettings(s.copyWith(autoSync: v)),
          ),
          ListTile(
            leading: const Icon(Icons.speed),
            title: const Text('并发传输数'),
            subtitle: const Text('小文件很多时提高并发可明显加速；默认按传输协议自动选择'),
            trailing: DropdownButton<int>(
              value: s.transferConcurrency,
              items: const [
                DropdownMenuItem(value: 0, child: Text('自动')),
                DropdownMenuItem(value: 4, child: Text('4')),
                DropdownMenuItem(value: 8, child: Text('8')),
                DropdownMenuItem(value: 12, child: Text('12')),
                DropdownMenuItem(value: 16, child: Text('16')),
                DropdownMenuItem(value: 24, child: Text('24')),
              ],
              onChanged: (v) async {
                if (v == null) return;
                await state.saveSettings(s.copyWith(transferConcurrency: v));
              },
            ),
          ),
          ListTile(
            enabled: s.autoSync,
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
          ListTile(
            leading: const Icon(Icons.merge_type),
            title: const Text('冲突处理策略'),
            subtitle: Text(_policyHint(s.conflictPolicy)),
            trailing: DropdownButton<ConflictPolicy>(
              value: s.conflictPolicy,
              items: const [
                DropdownMenuItem(
                    value: ConflictPolicy.newest, child: Text('最新优先')),
                DropdownMenuItem(
                    value: ConflictPolicy.preferLocal, child: Text('保留本地')),
                DropdownMenuItem(
                    value: ConflictPolicy.preferRemote, child: Text('保留远程')),
                DropdownMenuItem(
                    value: ConflictPolicy.keepBoth, child: Text('保留两份')),
                DropdownMenuItem(
                    value: ConflictPolicy.ask, child: Text('逐条询问')),
              ],
              onChanged: (v) async {
                if (v == null) return;
                await state.saveSettings(s.copyWith(conflictPolicy: v));
              },
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.rocket_launch_outlined),
            title: const Text('极速模式（信任本地目录 mtime）'),
            subtitle: Text(
                '目录 mtime 没变就整棵子树跳过，不上报文件；'
                '大目录树下快很多，但其他 App 对已有文件内容的修改要等全量校对才会被发现。'
                '每 ${s.turboFullScanMinutes} 分钟自动全量校对一次。'),
            value: s.turboScan,
            onChanged: (v) async {
              if (v) {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('开启极速模式'),
                    content: const Text(
                        '极速模式不会逐个检查文件，只根据目录修改时间判断。'
                        '如果别的 App 修改了文件内容（不改目录时间），'
                        '这些修改要等到下一次全量校对才会上传。'
                        '\n\n建议保留默认的定期全量校对，或随时手动「全量校对」。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('开启')),
                    ],
                  ),
                );
                if (ok != true) return;
              }
              await state.saveSettings(s.copyWith(turboScan: v));
            },
          ),
          if (s.turboScan)
            ListTile(
              leading: const Icon(Icons.timer),
              title: const Text('全量校对间隔'),
              trailing: DropdownButton<int>(
                value: [15, 30, 60, 180, 360, 720]
                        .contains(s.turboFullScanMinutes)
                    ? s.turboFullScanMinutes
                    : 60,
                items: const [
                  DropdownMenuItem(value: 15, child: Text('15 分钟')),
                  DropdownMenuItem(value: 30, child: Text('30 分钟')),
                  DropdownMenuItem(value: 60, child: Text('1 小时')),
                  DropdownMenuItem(value: 180, child: Text('3 小时')),
                  DropdownMenuItem(value: 360, child: Text('6 小时')),
                  DropdownMenuItem(value: 720, child: Text('12 小时')),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  await state.saveSettings(
                      s.copyWith(turboFullScanMinutes: v));
                },
              ),
            ),
          ListTile(
            leading: const Icon(Icons.fact_check_outlined),
            title: const Text('立即全量校对'),
            subtitle: const Text('忽略极速缓存，完整扫描本地与远程并校正差异'),
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              await state.syncAll(fullScan: true);
              messenger.showSnackBar(const SnackBar(content: Text('全量校对完成')));
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.bolt),
            title: const Text('快速扫描（跳过未变更的远程目录）'),
            subtitle: const Text(
                '利用 Nextcloud 目录 etag 跳过整棵未变化子树，大目录树可快数倍；'
                '若发现远程改动没被同步，可关闭它做一次全量扫描'),
            value: s.fastScan,
            onChanged: (v) => state.saveSettings(s.copyWith(fastScan: v)),
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
          SwitchListTile(
            secondary: const Icon(Icons.backup_outlined),
            title: const Text('自动备份配置（不含密码）'),
            subtitle: Text(
                '配置变化和每次同步后写入 Documents/NextcloudSync/ncsync-config.json'
                '（卸载重装也不会丢；密码需重新登录或手动导出含密码的版本）'
                '${state.lastAutoBackupAt == null ? '' : '\n上次备份：${formatTime(state.lastAutoBackupAt)}'}'),
            value: s.autoBackup,
            onChanged: (v) async {
              final messenger = ScaffoldMessenger.of(context);
              await state.saveSettings(s.copyWith(autoBackup: v));
              if (v) {
                final path = await state.autoBackupNow();
                if (path != null) {
                  messenger.showSnackBar(
                      SnackBar(content: Text('已备份到 $path')));
                }
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.save_outlined),
            title: const Text('立即备份'),
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              final path = await state.autoBackupNow();
              messenger.showSnackBar(SnackBar(
                  content: Text(path == null ? '备份失败（检查存储权限）' : '已备份到 $path')));
            },
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

  String _policyHint(ConflictPolicy p) => switch (p) {
        ConflictPolicy.newest =>
          '两边都改时保留修改时间较新的一份，同一次同步内直接完成',
        ConflictPolicy.preferLocal => '两边都改时总是用本机版本覆盖远程',
        ConflictPolicy.preferRemote => '两边都改时总是用远程版本覆盖本机',
        ConflictPolicy.keepBoth => '两边都改时自动改名保留两份（不询问）',
        ConflictPolicy.ask => '无法自动判断时进入「冲突」列表等待选择',
      };

  Widget _section(String title, ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(title,
            style: theme.textTheme.labelLarge
                ?.copyWith(color: theme.colorScheme.primary)),
      );
}
