# Nextcloud 同步（Android）

一个只做同步的 Android 客户端：把手机上的文件夹与 Nextcloud 上的目录做**双向同步**。
Flutter + Material 3 实现，只支持 Android。

## 功能

- **多组同步配对**：每组 = 一个本地文件夹 ↔ 一个 Nextcloud 目录
- **双向同步**：新增、修改、删除都会双向传播（远程删除进 Nextcloud 回收站，可恢复）
- **删除保护**：单次同步检测到超过 50% 且 >20 项的删除时自动中止，需要手动确认
- **冲突处理**
  - 能自动判断的自动处理（内容相同判为一致、单边修改直接传播）
  - 两边都改：自动保留两份（`文件名 (conflict 2026-11-03 2130 from 设备名).ext`），本地远程各一份
  - 无法判断的（一边删除一边修改、文件/目录类型冲突、仅大小写不同）进入「冲突」页，由你选保留哪边
- **登录方式**
  - 推荐：Nextcloud **Login Flow v2**，浏览器授权后自动拿到应用密码，不接触账号密码
  - 兜底：手动填服务器地址 + 用户名 + 应用密码
  - 凭据保存在 Android Keystore 加密存储（`flutter_secure_storage`），不写进数据库
- **后台同步**：WorkManager 周期任务（最短 15 分钟，可配置到 12 小时），支持「仅 Wi-Fi」、完成通知
- **手动同步**：首页「立即同步」/ 单个配对同步 / 下拉刷新
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

`MANAGE_EXTERNAL_STORAGE` 会导致无法上架 Google Play（政策限制）；自用、侧载或企业内部分发没有问题。

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

# 真机端到端
flutter test integration_test/sync_engine_test.dart -d <device> \
  --dart-define=NC_SERVER=... --dart-define=NC_USER=... --dart-define=NC_PASS=...
flutter test integration_test/ui_flow_test.dart -d <device> \
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
