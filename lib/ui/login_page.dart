import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../nextcloud/diagnose.dart';
import '../nextcloud/login_flow.dart';
import '../state/app_state.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _busy = false;
  String? _status;
  String? _error;
  LoginFlowSession? _session;
  bool _manual = false;
  bool _obscure = true;

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  String? _validateServer(String? v) {
    if (v == null || v.trim().isEmpty) return '请输入服务器地址';
    return null;
  }

  Future<void> _startFlow() async {
    if (_validateServer(_server.text) != null) {
      _snack('请输入服务器地址');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = '正在联系服务器…';
    });
    final state = context.read<AppState>();
    try {
      final session = await state.startLoginFlow(_server.text);
      if (!mounted) return;
      setState(() {
        _session = session;
        _status = '已打开浏览器，请在网页中点击「授权」';
      });
      final uri = Uri.parse(session.loginUrl);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        await launchUrl(uri);
      }
      await state.finishLoginFlow(session);
      if (!mounted) return;
      setState(() {
        _status = '授权成功';
        _session = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '登录失败：$e';
        _status = null;
        _session = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manualLogin() async {
    if (_validateServer(_server.text) != null) {
      _snack('请输入服务器地址');
      return;
    }
    if (_user.text.trim().isEmpty || _password.text.isEmpty) {
      _snack('请输入用户名和应用密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = '正在验证…';
    });
    try {
      await context
          .read<AppState>()
          .manualLogin(_server.text, _user.text, _password.text);
    } catch (e) {
      if (mounted) setState(() => _error = '登录失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }

  Future<void> _diagnose() async {
    final server = _server.text.trim();
    if (server.isEmpty) {
      _snack('请先填写服务器地址');
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('网络诊断'),
        content: Row(children: [
          SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 16),
          Text('正在测试连接…'),
        ]),
      ),
    );
    DiagResult? result;
    String? failure;
    try {
      result = await diagnoseServer(server);
    } catch (e) {
      failure = '$e';
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    if (!mounted) return;
    final theme = Theme.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(result?.ok == true ? '连接正常' : '连接失败'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (failure != null)
                Text(failure, style: TextStyle(color: theme.colorScheme.error)),
              for (final step in result?.steps ?? <DiagStep>[])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        step.ok ? Icons.check_circle : Icons.cancel,
                        size: 18,
                        color: step.ok
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${step.name}（${step.ms} ms）',
                                style: theme.textTheme.bodyMedium),
                            if (step.detail.isNotEmpty)
                              Text(step.detail,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.outline)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              if (result?.status?['version'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                      'Nextcloud ${result!.status!['version']}',
                      style: theme.textTheme.bodySmall),
                ),
              const SizedBox(height: 12),
              Text(
                '如果「TLS 握手」失败而浏览器能打开，通常是网络中间设备'
                '（公司代理、运营商、Cloudflare 风控）中断了连接：'
                '请切换网络（Wi-Fi/移动数据）、关闭代理或稍后重试。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.cloud_sync_rounded,
                        size: 72, color: theme.colorScheme.primary),
                    const SizedBox(height: 12),
                    Text('Nextcloud 同步',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text('在手机与 Nextcloud 之间双向同步目录',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.outline)),
                    const SizedBox(height: 28),
                    TextFormField(
                      controller: _server,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: '服务器地址',
                        hintText: 'https://cloud.example.com',
                        prefixIcon: Icon(Icons.dns_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: _validateServer,
                    ),
                    const SizedBox(height: 20),
                    if (!_manual) ...[
                      FilledButton.icon(
                        onPressed: _busy ? null : _startFlow,
                        icon: const Icon(Icons.open_in_browser),
                        label: const Text('使用浏览器授权登录'),
                        style: FilledButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 16)),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '推荐方式：跳转到浏览器登录并授权，应用只会拿到一个应用密码，'
                        '不会接触你的账号密码。',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                      if (_session != null) ...[
                        const SizedBox(height: 16),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(child: Text(_status ?? '等待授权…')),
                                ]),
                                const SizedBox(height: 12),
                                Text('浏览器没有自动打开？请点击下面的链接：',
                                    style: theme.textTheme.bodySmall),
                                const SizedBox(height: 4),
                                InkWell(
                                  onTap: () async {
                                    final uri =
                                        Uri.parse(_session!.loginUrl);
                                    await launchUrl(uri,
                                        mode: LaunchMode.externalApplication);
                                  },
                                  child: Text(
                                    _session!.loginUrl,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: theme.colorScheme.primary,
                                        fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() => _manual = true),
                            child: const Text('改为手动输入应用密码'),
                          ),
                          const SizedBox(width: 8),
                          TextButton.icon(
                            onPressed: _busy ? null : _diagnose,
                            icon: const Icon(Icons.network_check, size: 18),
                            label: const Text('网络诊断'),
                          ),
                        ],
                      ),
                    ] else ...[
                      TextFormField(
                        controller: _user,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: '用户名',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: '应用密码',
                          helperText: '在 Nextcloud「设置 → 安全 → 应用密码」中创建',
                          prefixIcon: const Icon(Icons.key_outlined),
                          suffixIcon: IconButton(
                            icon: Icon(_obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _busy ? null : _manualLogin,
                        style: FilledButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 16)),
                        child: const Text('登录'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() => _manual = false),
                        child: const Text('返回浏览器授权'),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(_error!,
                            style: TextStyle(
                                color: theme.colorScheme.onErrorContainer)),
                      ),
                    ],
                    if (_busy && _session == null) ...[
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 12),
                          Text(_status ?? '请稍候…'),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
