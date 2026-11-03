# Nextcloud Sync (Android) — 设计说明

Flutter 单端 Android 应用，做「本地目录 ↔ Nextcloud 目录」的双向文件同步。

## 已确认的需求

| 项 | 决定 |
|---|---|
| 范围 | A：仅同步（不做全账号浏览/相册备份），支持多组「本地目录 ↔ 远程目录」配对 |
| 认证 | Nextcloud **Login Flow v2**（首选，浏览器授权）+ 手动填地址/用户名/应用密码（兜底）；两种都存 app password |
| 冲突 | 能自动判定的自动处理，剩余情况进「待处理」列表让用户选 |
| 删除 | 双向同步删除（远程删除走 Nextcloud 回收站，可恢复） |
| 文件名 | 大小写敏感、符号链接、隐藏文件都按原样同步 |
| 触发 | 非实时：WorkManager 周期（≥15 分钟）+ 手动「立即同步」 |
| 文件类型 | 不区分，所有普通文件都同步 |

## 环境

- Nextcloud `35.0.2`（`https://cloud.example.com`），Login Flow v2 可用
- 测试设备：Android 16 (SDK 36) arm64，`192.0.2.10:5555`
- Flutter 3.32.8 / Dart 3.8.1，Android SDK 36

## 模块划分

```
lib/
  main.dart                 启动、Provider 注入、WorkManager 注册
  model/                    数据模型（Pair, RemoteEntry, LocalEntry, TransferTask, Conflict）
  store/
    db.dart                 sqlite：pairs / file_state / conflicts / logs
    secure_store.dart       凭据（flutter_secure_storage，Android Keystore）
    settings.dart           全局设置（周期、并发、Wi-Fi only…）
  nextcloud/
    client.dart             WebDAV：PROPFIND / GET / PUT / DELETE / MKCOL / MOVE，ETag 条件请求
    login_flow.dart         Login Flow v2 轮询 + 手动凭据校验
    capability.dart         status.php / capabilities 探测
  sync/
    engine.dart             单次同步的编排（扫描 → 计划 → 执行 → 落库）
    scanner.dart            本地递归扫描（符号链接/大小写/隐藏文件策略）
    planner.dart            三方对比（本地/远程/上次基线）生成动作
    conflict.dart           冲突判定与自动解决
    transfer.dart           上传/下载（流式、临时文件+改名、断点续传）
    scheduler.dart          WorkManager 周期任务 + 手动触发 + 互斥锁
  ui/
    home_page.dart          配对列表 + 同步状态
    pair_edit_page.dart     选择本地目录 / 远程目录、高级选项
    login_page.dart         服务器地址 + Login Flow v2 / 手动登录
    conflicts_page.dart     冲突列表，逐条选择保留哪边
    log_page.dart           同步日志 / 失败重试
```

## 同步算法

以每个配对为单位维护 sqlite `file_state`：`path, is_dir, etag, remote_mtime, size,
local_mtime, local_size, local_inode/dev, content_hash(可选), last_sync_at`。

一次同步：

1. **扫描远程**：从远程根做 BFS `PROPFIND Depth: 1`（Nextcloud 禁用 Depth: infinity），
   得到 `path → {etag, mtime, size, isDir}`。
2. **扫描本地**：递归遍历，得到 `path → {mtime, size, isDir, linkTarget}`。
   符号链接：跟随读取内容；若指向目录则记录目标并阻止再次进入（防环），
   链接本身的路径作为同步项。
3. **三方对比**：
   - 基线（上次同步记录）不存在：
     - 仅本地有 → 上传；仅远程有 → 下载；两边都有 → 若 etag/size+mtime 一致则记为已同步，
       否则按「新建冲突」处理。
   - 基线存在：
     - 本地未变 + 远程变 → 下载 / 删除本地
     - 本地变 + 远程未变 → 上传 / 删除远程
     - 两边都变 → 冲突
     - 两边都没了 → 删除基线
4. **删除特殊规则**：
   - 本地删除 + 远程修改 → 视为冲突（默认保留远程，恢复本地，可让用户选择）
   - 本地删除 + 远程也删除 → 一致，清基线
   - 远程删除 + 本地修改 → 冲突
5. **冲突自动解决**（仅限能确定的场景）：
   - 两侧内容哈希相同 → 直接判为一致
   - 一侧是「纯改名/移动」且内容一致 → 跟随移动
   - 无法自动判定 → 保留两边：远程文件 `MOVE` 为 `name (conflict 2025-..-.. from <device>).ext`，
     再下载/上传，并在 `conflicts` 表记录，UI 里可选用哪份、或删除。
6. **传输**：上传先 PUT 到 `.name.part-<uuid>` 再 `MOVE` 覆盖目标（原子替换），
   下载写 `.name.download-<uuid>` 再 rename；>10MB 使用 Nextcloud chunked upload
   （`/remote.php/dav/uploads/<user>/<id>`）以支持断点续传。
   写入/删除时用 `If-Match`/`If-None-Match` 防止覆盖并发修改（412 → 转冲突）。
7. **落库**：每个成功动作写入新基线；失败保留旧基线并记录日志，下次重试。

## 关键实现选择

- **本地目录访问**：Android 11+ 分区存储限制，Flutter 端直接 `dart:io` 访问 `/storage/emulated/0/xxx`
  需要 `MANAGE_EXTERNAL_STORAGE`（「所有文件访问权限」，设置页引导授予）。个人自用/侧载无上架问题；
  另提供「应用专属目录」选项（无需权限）。SAF 树形 URI 方案留作后续（Dart 侧实现复杂）。
- **大小写敏感**：远程（Linux）区分大小写，本地 `/sdcard` 的 FUSE 层不区分。同步时按
  `path.toLowerCase()` 检测同目录下的「仅大小写不同」的冲突条目，冲突时保留两边并改名。
- **字符归一化**：路径统一做 Unicode NFC 归一化比较，避免 NFC/NFD 造成重复文件。
- **凭据**：只存 app password，不存用户密码；`flutter_secure_storage` + `encryptedSharedPreferences`。
- **后台**：WorkManager 周期任务最短 15 分钟，`ExistingPeriodicWorkPolicy.keep`，
  加网络约束（可配置仅 Wi-Fi）；同步过程持有全局互斥锁，避免手动与后台叠加。
- **前台通知**：同步时用 WorkManager 的回调 + 应用内状态；如需「正在同步」常驻通知，
  后续可加前台服务（`FOREGROUND_SERVICE_DATA_SYNC`）。

## 权限

```
INTERNET, ACCESS_NETWORK_STATE
MANAGE_EXTERNAL_STORAGE（可选，仅当使用共享存储目录）
POST_NOTIFICATIONS（同步结果通知）
RECEIVE_BOOT_COMPLETED（重排周期任务）
```

## 实施状态（已完成并验证）

1. ✅ 工程骨架 + Material 3 主题 + sqlite 基线 + Keystore 凭据存储
2. ✅ Nextcloud 客户端：`status.php`、Login Flow v2、PROPFIND（Depth 0/1）、PUT/GET/DELETE/MKCOL/MOVE、ETag 条件请求（412 检测）
3. ✅ 扫描器 + 三方合并计划器（22 个纯单元测试覆盖删除/冲突/大小写/目录级联等）
4. ✅ 执行引擎：流式上传下载、临时文件原子替换、基线批量落库、删除安全阀、冲突保留两份
5. ✅ UI：登录、配对管理、远程目录浏览、同步进度、冲突处理、日志、设置
6. ✅ WorkManager 周期任务（15 分钟起）、通知、仅 Wi-Fi 门控
7. ✅ 真机验证（Android 16 / arm64）：
   - `test/client_live_test.dart`：真实服务器上的 WebDAV 生命周期（含 UTF-8 文件名、412）
   - `test/engine_live_test.dart`：真实服务器上的完整引擎流程（上传/幂等/下载/双向删除/目录删除/冲突保留两份/手动冲突处理）
   - `integration_test/sync_engine_test.dart`：同一流程在真机上跑通
   - `integration_test/ui_flow_test.dart`：真机 UI 流程（登录 → 添加配对 → 同步 → 远程文件校验）

## 暂停 / 继续

- `SyncCancelToken` 由 UI 持有，引擎在每个文件动作前检查
- 暂停时先 flush 已完成的基线，再返回 `paused=true` 的报告（`SyncReport.processed/total`）
- 继续 = 重新跑一次同步：已完成文件的基线已落库，`planSync` 自动跳过它们，只做剩余部分
- 粒度是「文件之间」；正在传输的单个大文件会先传完

## 配置备份格式

```json
{
  "schema": "nextcloud-sync-config",
  "version": 1,
  "exportedAt": "2026-11-03T14:00:00Z",
  "account": {"server": "https://...", "username": "...", "appPassword": "..."},
  "settings": {"deviceName": "...", "intervalMinutes": 15, "wifiOnly": false, "notify": true},
  "pairs": [{"name": "...", "localPath": "/storage/...", "remotePath": "Notes", "enabled": true}]
}
```

- `account` 仅在「含密码导出」时写入（明文，导出前有警告）
- 导入：`merge` 按 `(localPath, remotePath)` 去重；`replace` 先删除现有配对（不删除文件）
- 导入后重新排程 WorkManager；含密码时直接恢复登录

## 实现备注

- 目录自身不参与 mtime 比较（`planner.dart` 的 `dirLocalChanged`），否则「远程删了目录里的文件」会被我们自己的删除操作误判为本地修改
- 远程列目录失败会让整次同步失败，而不是当作「远程为空」，避免误删全部本地文件
- 删除安全阀阈值：单次删除数 > 20 且 > 基线 50% 时中止
- 冲突副本命名：`name (conflict YYYY-MM-DD HHMM from 设备名).ext`，本地与远程各留一份
- 冲突页的三个选项在「一侧已删除」时语义为：保留本地=删远程；保留远程=删本地
