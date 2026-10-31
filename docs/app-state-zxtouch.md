# Shadow AppState 与 ZXTouch HTTP/2

所有请求使用已认证 HTTP/2 和 Bearer 控制令牌。备份创建、恢复、删除和完整校验均通过 Shadow 唯一 helper 提供。旧 save、switch、createBaseline、describe、profile 和 sessionSupplement 保持退役。

## 依赖与执行入口

TrollVNC 依赖安装了 AppState API v1 的 Shadow。两项目通过
`vendor/shadow/sdk/AppState` 的客户端调用 Shadow 安装的 `shadow-cleaner`，
按操作启动 helper，完成后退出，无新增常驻服务。
源码由 `.gitmodules` 与 gitlink 固定，初始化使用：

```sh
git submodule update --init vendor/shadow
```

list/edit/backup/restore/delete/verify/download/upload 均委托 Shadow；TrollVNC 不再自行解析手机备份目录、
编辑清单或发布 state 文件。调用前检查 capabilities 的 API 版本、存储格式和操作支持；
Shadow 缺失或不兼容时明确报错，不回退到旧核心。

## 目录与当前身份

`POST /api/app-state/list` 请求仅为 `{"bundle_id":"lt.manodrabuziai.fr"}`。
Shadow helper 返回目录及当前身份，TrollVNC 转换为现有 HTTP 字段：

- `bundle_id`、`format=ShadowAppState2`。
- `backups[]`：`backup_id`、`kind`、`idfv`、`display_name`、`note`、`date`、`version`、`build`。
- Shadow 的 `unavailable`、`error`、`restorePending`、`recoverySource`、`finalizationPending` 等状态随条目保留。损坏项由 Shadow 标记，不再静默隐藏。
- `current_idfv` 独立于 Keychain 和 access token；没有身份时为 null，格式无效时报错。身份查询不启动目标 App 或 Keychain worker。

备份引用保持 `snapshot:<IDFV>`，不是磁盘路径。存储格式、目录访问和恢复状态规则由 Shadow 维护。目录查询不执行恢复或解压归档。
不要依赖旧协议的 `current_backup_id`、`restore_pending` 或 `duplicate_identity_backup_ids`，也不能通过 token 查询失败推断当前环境。

## 操作与结果

| 路径 | 参数与作用 |
| --- | --- |
| `/api/app-state/list` | bundle_id，由 Shadow 查询目录及当前 IDFV |
| `/api/app-state/edit` | bundle_id、backup_id、display_name、note，由 Shadow 修改标题和备注并保护 pending 恢复源 |
| `/api/app-state/backup_and_reset` | 必填 bundle_id、idfv；Shadow 停止 App 并核对当前 IDFV，完整备份成功后全量清理、刷新指纹、校验；不支持跳过备份或指定步骤 |
| `/api/app-state/backup` | bundle_id，可选 display_name/note，仅将提供的字段交给 Shadow 创建或更新当前 IDFV 快照 |
| `/api/app-state/restore` | bundle_id、backup_id，可选 save_current 布尔值，默认 true；显式恢复重试可传 false |
| `/api/app-state/delete` | bundle_id、backup_id，由 Shadow 删除所选快照并保护 pending 恢复源 |
| `/api/app-state/verify` | bundle_id、backup_id，由 Shadow 对归档与逻辑载荷执行完整校验，不恢复或启动 App |
| `/api/app-state/launch` | bundle_id，启动并确认主进程出现 |
| `/api/app-state/stop` | bundle_id，关闭主进程及扩展并确认全部退出 |
| `/api/app-state/status` | bundle_id，只读 installed/running/main_running/extension_process_count/pids |
| `/api/app-state/result` | operation_id，查询原操作，不重复发送变更 |

异步操作返回 `operation_id`、`method`、`status`。`status=completed` 只表示已结束，还必须检查 `error` 与 `result`。结果在内存保留600秒，不跨服务重启；查询超时不能重放原变更。错误保留原 numeric `code`、`domain` 和可读 `message`，新增稳定字符串 `error_code`，例如 invalid_request、unsupported_operation、busy、shadow_unavailable、shadow_incompatible、operation_failed。Shadow 的 errorCode 原样映射，不根据翻译后的错误文本推断。`outcome_unknown` 表示无法确认原操作结果，不能据此自动重试。上传/下载错误保留顶层 error 字符串并提供相同 error_code/message/outcome_unknown 字段。

错误码与状态：invalid_request/unsupported_operation 为400，busy/restore_pending/active_environment/snapshot_changed 为409，permission_denied 为403，snapshot_unavailable 为404，shadow_unavailable/shadow_incompatible 为503，invalid_archive 为422，outcome_unknown 为504，operation_failed 为500。异步操作一旦取得 operation_id，其运行或终结记录始终通过 HTTP200 返回；必须读取 error/error_code。同步拒绝及原始上传/下载失败才使用对应非200状态。

backup/restore/verify 的 helper 进度沿用 operation_id/result/stream，包含 phase、stage、bytes、entries；完成不自动启动 App。

请求示例（均为 POST，请带现有 Bearer 控制令牌）：

```text
/api/app-state/backup
{"bundle_id":"com.example.app","display_name":"工作环境","note":"切换前保存"}

/api/app-state/restore
{"bundle_id":"com.example.app","backup_id":"snapshot:11111111-2222-3333-4444-555555555555","save_current":true}

/api/app-state/delete
{"bundle_id":"com.example.app","backup_id":"snapshot:11111111-2222-3333-4444-555555555555"}

/api/app-state/verify
{"bundle_id":"com.example.app","backup_id":"snapshot:11111111-2222-3333-4444-555555555555"}
```


launch/stop/status 保留 TrollVNC 独立应用控制实现。stop 对经过 UID、PID/start time、canonical path 核对的进程发送 SIGTERM，再对原身份仍存在的进程发送 SIGKILL，最后重新检查退出。仅请求 ACK 不表示 App 已关闭。Apple 系统 App 与 TrollVNC 自身禁止通过此入口启动／关闭。

## 所选备份 state 传输

`/api/app-state/download` 按 canonical Bundle、snapshot 引用和 part 委托 Shadow 导出 manifest/state，不执行恢复或导入。下载 state 时提交从 manifest 取得的 state SHA，避免混用不同版本。

`/api/app-state/upload` 保留 state 在先、manifest 在后的分块协议，但 state 完成只表示 TrollVNC 已暂存，尚未发布。首次暂存通过 Shadow 捕获当前 manifest SHA 和 data SHA；所有分块检查偏移、长度、传输身份及校验和。manifest 完成后将完整文件对交给 Shadow，Shadow 在应用锁内重新检查快照版本、pending 保护和归档内容，再原子发布整个快照，保留 mobile 属主及私有权限。TrollVNC 不直接写手机备份文件。

全进程仅允许一个上传事务，最多 64MiB state + 16MiB manifest；内存暂存在下一次请求时回收超过600秒的事务，服务重启即丢失。提交失败或结果未知会释放暂存，不自动提交第二次。上传不传输 data、不写 live Keychain／偏好、不创建备份或启动 App。

`/api/apps/access-token` 仍是独立的 Vinted 手机实时 access token 读取入口，含当前 IDFV、到期元数据和白名单请求头，不返回 refresh token。它依赖 Keychain token 能被读取，不能代替通用当前身份查询。

RV 接管前后比对 `current_idfv`。目标仍为 active 时提示用户在 Shadow 保存最新备份并切换，不自动备份或切换，也不读取旧 state 后直接采用。

## 验证

```sh
rtk proxy sh vendor/app-state/build.sh test
rtk proxy bash tests/run_app_state_stream_tests.sh
rtk proxy python3 tests/AppStateHTTPTests.py
```

主机测试覆盖 helper 能力协商、字段映射、暂存事务、原始错误传播与结果未知时不重放，以及 retained core／原生模拟测试。历史 core 中存在 save/switch 不代表公共接口开放。2026-10-31 已在 iPhone9,2 / iOS15.8.8 安装本轮兼容版本。已认证 HTTP/2 的列表、当前身份、完整校验及原始下载通过；两份现有备份在独立临时目录解压后逐文件核对通过，手机原文件哈希、权限与修改时间保持不变。真机发现并修正当前身份持久化路径读取问题。遵照只读验收范围，未执行备份创建、恢复、删除、编辑或回写；这些变更操作仍仅有主机测试与构建验证。

## 最小 ownership

新增异步 `claim`、`release`、`ownership`，参数均为bundle_id、backup_id，结果含owner=phone|rv及owner_id=null。active或pending恢复源不能claim；同一单RV重复claim/release由Shadow幂等处理。既有列表补充归属字段，缺失视为phone。无控制凭证、generation、租约或超时释放。

edit/delete/verify/download/upload可选requester=phone|rv，省略为phone。上传事务绑定requester，开始导出和最终发布使用同一上下文；普通backup/restore始终为phone。归属不符由Shadow返回ownership_conflict，HTTP409（已有operation_id的异步结果仍HTTP200）。requester是合作客户端的操作上下文，不是新的安全认证。归属规则仅由Shadow核心执行；TrollVNC不直接改manifest owner。

## 自动备份并重置

`backup_and_reset` 整体委托 Shadow `backupAndReset`，TrollVNC 不编排独立 backup/clean。
只接收 `bundle_id`、`idfv`；服务端规范化 UUID，拒绝步骤、元数据、requester 或跳过备份选项。
成功返回 `backup_id`、`previous_idfv`、`current_idfv`、`reset`、`verified`。
`idfv_mismatch` 为409，已有 operation_id 的终结记录仍HTTP200并通过error说明失败。
已知清理失败保留 error.backup_id、step、state_may_be_partial，未知结果不自动重放。
Shadow 使用现有 pending 恢复保护备份；中断重置后显式恢复应传 save_current=false，
即使 IDFV 尚未刷新也允许完整恢复该 pending 来源；普通 active 恢复规则不变。

2026-10-31：Shadow 4.0.6 与 TrollVNC 4.0-17 已安装到此前确认的 iPhone13
（iPhone14,5），HookKit 保持 3.0.6-1。安装包与 staging 的字节、mode 和 numeric
root 所有权匹配，上传 SHA256 一致；dpkg 均为 install ok installed。
已通过 Python SDK 认证 HTTP/2、backup_and_reset 缺少 IDFV 的400/invalid_request
拒绝，以及只读目录查询。Shadow helper 的 capabilities 包含 backupAndReset。
安装前后133个现有备份文件的 SHA256 全部一致。没有执行真实 App 备份、重置、
恢复、启动或所有权变更；完整清理仍需单独授权真机验收，不能从这些只读检查宣称已实测。
