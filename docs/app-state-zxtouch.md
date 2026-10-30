# App state：当前 ZXTouch HTTP/2 接口

所有请求使用已认证 HTTP/2 和 Bearer 控制令牌。备份创建、恢复和环境切换由 Shadow 提供，RV 不调用旧 save、switch、createBaseline、delete、describe、profile 或 sessionSupplement。

## 目录与当前身份

`POST /api/app-state/list`，请求仅为 `{"bundle_id":"lt.manodrabuziai.fr"}`。完成结果：

- `bundle_id`、`format=ShadowAppState2`。
- `backups[]`：`backup_id`、`kind`、`idfv`、`display_name`、`note`、`date`、`version`、`build`。
- 4.0-16 新增 `current_idfv`：独立读取 Shadow 当前指纹的 VendorIdentifier，不访问 Keychain、不要求存在 access token、不启动 worker。明确没有身份时为 null；存在但格式无效时报错，不能误报为 null。

备份目录取自 `/private/var/mobile/Library/ShadowBackups/<BundleID>/snapshots/<IDFV>/manifest.plist`，引用仍为 `snapshot:<IDFV>`。目录不打开、校验或解压归档，不修改备份或指纹。

不要要求旧协议中的 `current_backup_id`、`restore_pending` 或 `duplicate_identity_backup_ids`。4.0-15 没有独立的当前 IDFV 字段；使用该功能需要更新手机服务，不能通过实时 token 读取失败来推断 active 状态。

## 操作与结果

| 路径 | 参数与作用 |
| --- | --- |
| `/api/app-state/list` | bundle_id，读取上述目录和当前 IDFV |
| `/api/app-state/edit` | bundle_id、backup_id、display_name、note，仅修改所选快照标题和备注 |
| `/api/app-state/launch` | bundle_id，启动并确认主进程出现 |
| `/api/app-state/stop` | bundle_id，关闭主进程及扩展并确认全部退出 |
| `/api/app-state/status` | bundle_id，只读 installed/running/main_running/extension_process_count/pids |
| `/api/app-state/result` | operation_id，查询原操作，不重复发送变更 |

这些异步操作返回 `operation_id`、`method`、`status`。`status=completed` 只表示已结束，还必须检查 `error` 与 `result`。结果在内存保留600秒，不跨服务重启；查询超时不能重放原变更。

stop 先对经过 UID、PID/start time、canonical path 核对的进程发送 SIGTERM，再对原身份仍存在的进程发送 SIGKILL，最终重新检查退出。仅请求 ACK 不表示 App 已关闭。Apple 系统 App 与 TrollVNC 自身禁止通过此入口启动／关闭。

## 所选备份 state 传输

- `/api/app-state/download`：按 canonical Bundle、snapshot引用及 part 读取 manifest/state；不执行恢复或导入。
- `/api/app-state/upload`：仅在用户明确交给手机时，顺序回写所选现有快照的 state、manifest；使用 SHA、偏移、大小和手机当前 data 哈希校验，保留 mobile 属主及0600。不上传 data、不写 live Keychain／偏好、不创建备份或启动 App。
- `/api/apps/access-token`：独立的 Vinted 手机实时 access token 读取入口，含当前 IDFV、到期元数据和白名单请求头；不返回 refresh token。它依赖 Keychain token 能被读取，不能充当通用 active 身份查询。

RV 接管前后比对目录的 `current_idfv`。目标仍为 active 时提示用户在 Shadow 保存最新备份并切换，不自动备份或切换，也不读取旧 state 后直接采用。

## 验证

`rtk proxy sh vendor/app-state/build.sh test` 覆盖现行 facade、目录字段、身份规范化、无 token 的身份读取，以及 retained core／原生模拟测试。历史 core 中存在 save/switch 实现不代表公共接口仍开放；手机实际行为必须以安装版本的 HTTP/2 返回验证。
