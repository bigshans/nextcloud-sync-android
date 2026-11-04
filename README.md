# Nextcloud 同步（Android）

一个只做同步的 Android 客户端：把手机上的文件夹与 Nextcloud 上的目录做**双向同步**。
Flutter + Material 3 实现，只支持 Android。

## 功能

- **多组同步配对**：每组 = 一个本地文件夹 ↔ 一个 Nextcloud 目录
- **双向同步**：新增、修改、删除都会双向传播（远程删除进 Nextcloud 回收站，可恢复）
- **删除保护**：单次同步检测到超过 50% 且 >20 项的删除时自动中止，需要手动确认
- **冲突策略**（设置里选一种，全局统一、当次同步就处理完）
  - **最新优先（默认）**：比较修改时间，保留较新的一份，一次同步内解决
  - **保留本地 / 保留远程**：统一用一侧覆盖另一侧
  - **保留两份**：自动改名，本地远程各留一份
  - **逐条询问**：进入「冲突」页人工选择
  - 冲突副本命名与 Nextcloud 官方客户端一致：`名称 (conflicted copy 设备名 2026-11-03 143005).ext`
  - 删除 vs 修改这类无法比较新旧的场景：保留数据（恢复被删的一侧）；「保留本地/保留远程」则按你的选择删除
- **登录方式**
  - 推荐：Nextcloud **Login Flow v2**，浏览器授权后自动拿到应用密码，不接触账号密码
  - 兜底：手动填服务器地址 + 用户名 + 应用密码
  - 凭据保存在 Android Keystore 加密存储（`flutter_secure_storage`），不写进数据库
- **后台同步**：可完全关闭；开启时 WorkManager 周期任务（最短 15 分钟，可配置到 12 小时），支持「仅 Wi-Fi」、完成通知
- **进度显示**：当前并发传输的文件列表（文件名 + 尾部路径 + 单文件字节进度）、上传/下载/删除/失败计数、整体进度
- **412 冲突即时处理**：条件上传遇到 412 时按当前冲突策略当场解决，不再反复失败重试
- **小文件优化**：HTTP/2 多路复用（无逐文件握手）+ 并发可调（默认自动：HTTP/2 下 16 路）+ 连接保活 5 分钟
- **手动同步**：首页「立即同步」/ 单个配对同步 / 下拉刷新
- **暂停 / 继续**：同步过程中可随时暂停（当前这一小批传完后停下），已完成的部分不会重传，点「继续」从中断处接着做
- **速度**
  - 传输 8 路并发（连接池 16）
  - 远程：根目录 etag 未变时整棵树都不扫；否则用目录 etag 跳过未变化子树
  - 本地：扫描按顶层目录分片到多个 isolate 并行（20k 文件从 2.0s 降到 0.27s）
  - 无变化的同步不再重写基线（大目录树下省掉几万次数据库写入）
- **配置导出 / 导入**：设置页可导出 JSON（可选是否包含应用密码），换机或重装后一键恢复账号、设置与全部同步配对；导入支持「合并」或「覆盖」
- **自动备份**：默认开启，配置变化/同步后自动写入 `Documents/NextcloudSync/ncsync-config.json`（不含密码，卸载重装也不会丢）
- **文件处理**：所有普通文件类型，支持隐藏文件、Unicode 文件名、符号链接（链接到文件按内容同步，链接到目录不递归以防环）、大于 32MB 的文件流式上传
- **可观测**：同步进度、每个配对的最近结果、冲突列表、同步日志

## 安装

```bash
# 已构建好的 APK
build/app/outputs/flutter-apk/app-release.apk

adb install -r build/app/outputs/flutter-apk/app-release.apk
```

或自行构建：

```bash
flutter pub get
flutter build apk --release
```

> Release 版使用 debug 签名（自用/侧载没问题）。要上架或分发请自行配置签名。

## 使用

1. 打开应用 → 填服务器地址（如 `https://cloud.example.com`）
2. 点「使用浏览器授权登录」并在浏览器里点「授权」；或「改为手动输入应用密码」
3. 首页「添加同步」→ 选择本地文件夹、远程目录（可浏览）
   - 同步共享存储（如 `/storage/emulated/0/Notes`）需要授予「所有文件访问权限」，应用内会提示跳转
   - 也可以只同步应用专属目录（无需任何权限）
4. 点「立即同步」，或等待后台周期同步
5. 有冲突时首页右上角冲突图标会显示数量，进去逐条选择「保留本地 / 保留远程 / 两份都保留」

## 权限说明

| 权限 | 用途 |
|---|---|
| `INTERNET` / `ACCESS_NETWORK_STATE` | 访问 Nextcloud / 判断是否 Wi-Fi |
| `MANAGE_EXTERNAL_STORAGE` | 同步共享存储中的任意文件夹（可选，需在系统设置中手动授予） |
| `POST_NOTIFICATIONS` | 同步结果通知（Android 13+） |
| `RECEIVE_BOOT_COMPLETED` / `WAKE_LOCK` | 重启后恢复周期任务 |

开发提示：`flutter test -d <设备>` 会在测试结束后**卸载应用**（数据一并清除）。
因此集成测试默认跳过，必须显式传 `--dart-define=NC_DEVICE_TEST_OK=true`，并且只对模拟器执行。

`MANAGE_EXTERNAL_STORAGE` 会导致无法上架 Google Play（政策限制）；自用、侧载或企业内部分发没有问题。

## 连接失败排查

登录页点「网络诊断」，会逐层测试并显示结果：

| 步骤 | 失败意味着 |
|---|---|
| DNS 解析 | 域名解析不了：检查地址拼写、DNS、是否被污染 |
| TCP 连接 | 端口被防火墙/运营商拦截，或服务器没开 |
| TLS 握手 | 网络中间设备（公司代理、运营商、Cloudflare 风控）中断了 TLS，或设备时间不准 |
| HTTPS 请求 | 能握手但拿不到 `status.php`：证书域名不匹配、反向代理配置错误、Cloudflare 拦截 |

如果「TLS 握手」失败而手机浏览器可以打开同一个地址，基本可以确定是网络中间设备的问题：
切换 Wi-Fi/移动数据、关闭 VPN/代理、校准系统时间后重试。应用本身对握手失败会自动重试 6 次（指数退避）。

## 已知限制

- 单账号（多账号未实现）
- 不做「实时监听」，后台最短 15 分钟（Android WorkManager 限制）
- 不处理 Nextcloud 服务端加密（E2EE）文件
- 符号链接目录不递归同步
- 大文件未使用 Nextcloud 分块上传（断点续传），超大文件中断后会重传

## 开发

```bash
flutter analyze
flutter test                      # 单元测试 + 对真服务器的客户端/引擎测试
```

测试用的真实服务器基准：

```bash
# 凭据来自 ~/.config/ncsync/test_creds.json（Login Flow 辅助写入，勿提交）
flutter test test/engine_live_test.dart      # 引擎端到端（真实服务器）
flutter test test/client_live_test.dart      # WebDAV 客户端（真实服务器）

# 端到端（只用在模拟器或备用机上！）
# `flutter test -d` 会在结束后卸载应用，真机上会丢配置。
flutter test integration_test/sync_engine_test.dart -d emulator-5554 \
  --dart-define=NC_DEVICE_TEST_OK=true \
  --dart-define=NC_SERVER=... --dart-define=NC_USER=... --dart-define=NC_PASS=...
flutter test integration_test/ui_flow_test.dart -d emulator-5554 \
  --dart-define=NC_DEVICE_TEST_OK=true \
  --dart-define=NC_SERVER=... --dart-define=NC_USER=... --dart-define=NC_PASS=...
```

### 结构

```
lib/
  models/        数据模型
  store/         sqlite 基线、凭据、设置
  nextcloud/     WebDAV 客户端、Login Flow v2
  sync/          扫描、三方合并计划器、执行引擎、WorkManager、通知
  state/         AppState（ChangeNotifier）
  ui/            登录 / 首页 / 配对编辑 / 冲突 / 日志 / 设置
```

同步算法（本地 / 远程 / 上次基线三方对比）见 `ARCHITECTURE.md`。
