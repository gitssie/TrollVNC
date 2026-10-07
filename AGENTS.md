# TrollVNC 开发与真机测试记忆

RV/VNC 密码与设备解锁密码复用现有本地配置，不添加系统钥匙串保存、读取、迁移或依赖。

## Apple 模块位置与边界

- `vendor/apple/` 是独立 Objective-C / Foundation 原生账户模块；修改前读取 [模块 AGENTS.md](vendor/apple/AGENTS.md)、[接口](vendor/apple/docs/interface.md)、[验证记录](vendor/apple/docs/validation.md)。
- `vendor/appstorectl/` 是平级 vendor，保留完整固定上游快照及许可；不得移进 apple/third_party 或增加 upstream 层。
- 暂不将 Apple 模块接入 TrollVNC 构建、VNC 协议、服务或 UI。使用 Apple 框架，不使用 ZXTouch、坐标点击或页面刷新来完成账户操作。
- 公共入口：[TVAppleServices.h](vendor/apple/include/TVAppleServices.h)。`src/appleid/` 为共享编排，`src/icloud/` 为 iCloud 开通、退出、Find My 和数据策略，`src/appstore/` 为 Store/AuthKit 适配，`src/common/` 为原生后端。

## 已提供的接口

| 方法 | 用途 |
| --- | --- |
| `enableICloudAppleID:password:devicePasscode:verificationCodeProvider:completion:` | 原生认证、本机密码验证、CoreCDP、数据服务开通，保持 Find My 关闭 |
| `queryAppleIDEmailSettings:completion:` | fresh AuthKit联系邮箱与公共隐藏邮箱forwarding_email；非iCloud Mail |
| `beginAddingContactEmail:appleID:completion:` / `verifyContactEmailChallenge:code:appleID:completion:` | 新增联系邮箱，外部单独提交邮箱验证码，同一Services实例 |
| `setSignInWithAppleForwardingEmail:appleID:completion:` | 已验证邮箱设为全局SIWA隐藏邮箱转发地址，fresh查询验证 |
| `queryState:` | 聚合主 iCloud、idms、App Store、Find My、能力及原生姓名/邮箱（分项状态） |
| `disableFindMyAppleID:password:completion:` | Apple ID 密码验证、取得原生令牌、关闭本机 Find My 并查询验证 |
| `signOutICloudAppleID:localDataPolicy:completion:` | 仅直接删除指定主 iCloud 账户；最终查询验证 |
| `signOutAppleID:localDataPolicy:completion:` | 指定账户的主 iCloud → idms → 当前媒体退出 |
| `signInAppStoreAppleID:password:verificationCodeProvider:completion:` | Store/AuthKit 登录；验证码由调用方单独提交 |

Settings 主 iCloud、idms 和 App Store 必须分别判断；不能将媒体登录说成 iCloud 开通。非媒体记录的 `authenticated=false` 不是未登录判据。历史 `selected=false` 媒体记录不代表当前登录。独立开通 iCloud 已提供，须验证原生 CDP 完成。

## 主机测试与真机工具构建

以下命令从 **TrollVNC 目录**运行，需要 macOS、Xcode SDK，真机工具签名需要 ldid。

```bash
rtk proxy bash vendor/apple/tests/run_tests.sh
rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-state
rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-login apple-login.m
rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-findmy-disable apple-findmy-disable.m
rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-icloud-logout apple-icloud-logout.m
rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-logout apple-logout.m
rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-icloud-enable apple-icloud-enable.m
```

2026-10-07 主机测试 71 项通过，ARC、`-Wall -Wextra -Werror`。包含账户域隔离、策略、未知结果写栅栏、认证挑战及正式 Find My 状态 reader 的回归；不能代替真机私有 API 验证。

`apple-state` 默认只读；`--self-test` 仅用随机不存在的目标验证幂等空操作。其余工具会实际修改设备。参数通过标准输入 JSON 传入：

- icloud-enable：`apple_id`、`password`、`device_passcode`；验证码同 login 外部提交。
- login / findmy-disable：`apple_id`、`password`。
- logout / icloud-logout：`apple_id`、显式 `local_data_policy`（`remove` / `keep`）。remove 不合并，允许系统提供的删除/丢弃未上传数据动作。
- login 验证码：收到挑战后再提交 `challenge_id`、`code`；取码在模块外完成，模块不存 URL、不轮询。

不要把密码、验证码、令牌或取码 URL 写入源码、文档、命令参数、环境变量或日志。原生 error userInfo/请求 body/headers 也不输出。

## 通用 SSH 脚本

固定脚本：[tests/device-ssh.sh](vendor/apple/tests/device-ssh.sh)。换设备时只修改顶部 `DEVICE_HOST`、`DEVICE_PORT`、`DEVICE_USER`、`DEVICE_KNOWN_HOSTS`；这些是脚本内部变量，不导出环境变量，不配置密码。

```bash
rtk proxy bash vendor/apple/tests/device-ssh.sh /usr/bin/apple-state
rtk proxy bash vendor/apple/tests/device-ssh.sh /usr/bin/apple-findmy-disable
rtk proxy bash vendor/apple/tests/device-ssh.sh /usr/bin/apple-icloud-logout
```

脚本接受远端程序和参数，逐项引用；不解释管道/重定向等 shell 表达式。敏感输入走 stdin。交互终端关闭回显，正常退出、失败或信号中断后恢复原终端状态。使用 SSH 密钥、`-T`、`BatchMode=yes`、`StrictHostKeyChecking=yes`；应预先独立核对并保存 host key，不能为换机而关闭校验。

当前临时连接为 mobile@10.17.12.17:2222，known-hosts 为 `/tmp/cazer-iproxy-10.17.12.17-known-hosts`；以后必须核对实际地址，不能当作永久配置。

SCP 示例（同样按实际连接调整）：

```bash
rtk proxy scp -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=/tmp/cazer-iproxy-10.17.12.17-known-hosts \
  -P 2222 /tmp/apple-state mobile@10.17.12.17:/tmp/apple-state
```

测试系统为 Dopamine / RootHide、iOS 15.8.8、arm64。上传后在设备 root shell 用 `cp -f` 安装到 jailbreak `/usr/bin/`、`chmod 755`，并用 `jbctl trustcache add` 加入**实际原生 jailbreak root**路径的 trustcache。RootHide shell 路径与原生路径可能不同；不要硬编码旧的 `.jbroot-*`。root 不代替 entitlement；Find My 工具按原生 Settings 路径以 mobile 身份执行。

本次设备已部署的工具名为 `/usr/bin/cazer-apple-state-icloud-v1`、`/usr/bin/cazer-apple-findmy-disable-v3`、`/usr/bin/cazer-apple-icloud-logout-v6`、`/usr/bin/cazer-apple-icloud-enable-v3`。这些是临时测试版本，重新编译后应使用新名称并重新签名、信任。

## 真机结果与必须记住的细节

- Find My 已真实关闭：AuthKit 的 `AKPassword` 绑定主账户副本 → `AAFMIPAuthenticateRequest` → `fmipWipeToken` → `FMDFMIPManager.disableFMIPUsingToken:inContext:completion:`，此机 Settings context 为 1。不能用带 nil UDID 的配对设备接口关闭本机。
- `AARequest` 回调是 `(request, AAResponse, NSError)`；HTTP 响应在 `AAResponse.httpResponse`，不是第一个参数。令牌不保存、不返回。
- 此机原生状态 0/1 表示开启，3 表示关闭；2/4/其他状态或任意 error 均拒绝。关闭实测 daemon=3/error=nil、shared fmipActive=false、Settings 原生缓存 enabled=false；修正工具返回 succeeded/already_disabled=true。
- 独立 iCloud remove 策略已真实提交；全新查询确认目标主 iCloud 消失，idms 和活动已认证 App Store 仍在，Find My 关闭。首次退出工具返回 unknown，当时未记录回调元数据；本次同症状的 YES+Accounts/17 已定位，见文末；之后确认状态，再用新工具验证 succeeded/already_signed_out=true。
- unknown 不等于没有副作用。删除不确定时附带 fresh state 和 `target_signed_out`（可查询时），仍保持 unknown 与写栅栏，不自动重放。最终报告要区分实际账户退出、回调异常与幂等复验。
- 最终修正版尚未从重新开启 Find My / 重新登录 iCloud 的状态完整复跑，不能把分段验证说成一轮全流程回归。
- iCloud 开通已在正式模块完成：原生 AuthKit → AASignInFlowController → CoreCDP 本机密码验证 → dataclasses。首次部分保存后密码验证失败，返回 unknown；补 keystore.device 后再完成原生 CDP，返回 succeeded/already_enabled=true，Find My=false。两阶段验证，不是一次全流程回归。已有账户不能跳过 CDP；provider.failure 必须覆盖 Apple 的 non-fatal 保存成功。详见模块 AGENTS.md。
- App Store 登录已真机确认；正式 bootstrap 尚未在全新未信任设备完整回归。

账户退出只验证全新账户状态，不需要 Settings 页面刷新验证。系统日志诊断仅保留时间、进程、静态 format、错误 domain/code；不导出完整 composed message 或认证材料。详细证据、权限与局限持续更新到模块 AGENTS.md 和 docs/validation.md。

2026-10-07 开通后整机退出集成测试入口为 `vendor/apple/tests/apple-logout.m`，直接复用现有 signOutAppleID，无新增生产退出逻辑。首次 iCloud 删除回调 unknown 但全新查询确认主账户消失；确认后新进程只处理剩余 identity/media，返回 succeeded、verified_all_domains_signed_out=true、selected_accounts=[]，Find My=false。这是两阶段完整退出，iCloud 删除回调异常仍待排查。当前部署 `/usr/bin/cazer-apple-logout-v2`。输入要求显式 remove/keep，不存凭据。

后续已定位 iCloud 删除 unknown 的原因：原生回调 YES + com.apple.accounts/17，对应 dataclass 动作错误；账户已经移除。修复仅在该确切组合并全新确认账户消失/FindMy关闭时返回账户退出成功，同时保留 warnings/dataclass_action_failed；不保证全部本地数据动作完成。其他错误/false/超时仍unknown。当前整机测试工具 cazer-apple-logout-v4；诊断版本仅用于复现，不能用于正式服务。

修正版真机一次整机退出已通过，warnings保留数据动作17。循环中SearchParty daemon挂起曾令账户保留/超时，测试时仅重启 com.apple.icloud.searchpartyd 后恢复；当时模块未自动恢复；现已补充删除前健康检查及一次 SearchParty 恢复，见下文，不跳过FindMy或账户验证。defaultStore对照无效并撤回。正式已部署 cazer-apple-logout-v5、cazer-apple-login-v5、cazer-apple-icloud-enable-v4；测试详情见模块 docs/validation.md。

修复后的登录复测已完成：全退出后 App Store 原生登录 succeeded，无新验证码；接着 iCloud 一次开通 succeeded/already_enabled=false，最终 icloud/identity/media 全部选中、主账户数据服务启用、Find My关闭。设备保留此登录/开通状态。71项主机回归和arm64工具编译签名通过，退出误判修复已独立审查。

SearchParty 自动恢复已实现于 `vendor/apple/src/icloud/TVAppleSearchParty.m`：iCloud 删除前5秒原生只读探测，无响应时固定 root helper 恢复一次，复检10秒通过才提交删除；失败在预检返回，不重复提交。helper 用 `vendor/apple/tests/build_service_recovery.sh` 构建，部署 root:wheel/4755 到 bootstrap `/usr/bin/cazer-apple-searchparty-recover` 并加入实际 native trustcache；RootHide 使用真实路径解析，无环境变量配置。helper 自己监督固定 launchctl 子进程4秒期限。需要 beaconmanager entitlement，见模块 AGENTS.md。真机暂停 SearchParty 的故障整机退出、正常登录→开通→退出均通过，恢复元数据为 `service_recoveries`。健康诊断入口 `apple-searchparty-health.m` 也会在无响应时执行一次恢复。当前正式退出测试工具为 `/usr/bin/cazer-apple-logout-v11`；账户删除后仍保留 Accounts/17 数据动作警告。


Apple ID 邮箱工具：`rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-email-actions apple-email-actions.m`，部署/签名/trustcache后用 `rtk proxy bash vendor/apple/tests/device-ssh.sh /usr/bin/apple-email-actions`。同一个进程stdin依次给action=begin（email/ apple_id）、verify（challenge_id/code/apple_id）、forward（email/apple_id）或query；同一 Services 实例保留5分钟原生邮箱会话。这里要邮箱验证码，不能用受信任设备2FA码，不取码/轮询。独立只读工具 apple-email-settings.m 也可构建。新增/验证码/全局forward真机已分段执行成功，服务端reachable_emails与forwarding_email验证通过；随后用户确认实际邮件投递正常；模块自身不发信/查收。生产与测试细节见模块AGENTS.md，`tests/EmailActionsTests.m`覆盖原生postback/终止顺序/超时/精确forward表单/challenge/写栅栏。公共forward入口来自AKURLBag.privateEmailManageURL，不能用个人信息表单或Vinted单个App详情入口替代。


Apple ID Settings 姓名工具：公共 `queryAppleIDNameSettings` / `setAppleIDFirstName:lastName:appleID` 在 `vendor/apple`。构建 `rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-name-settings apple-name-settings.m`，部署/trustcache后用device-ssh.sh运行；stdin JSON action=query/apple_id，或set/apple_id/first_name/last_name。保留表单Middle Name，原生Settings签名与POST后全新服务端查询验证；unknown共用写栅栏，不做UI操作。真机已将First=jack、Last=ma保存并独立查询确认，Middle为空保持不变，同值幂等通过。技术细节与验证边界见模块AGENTS.md/docs/validation.md。


queryState现聚合apple_settings.name/email及app_store/icloud/identity摘要，保留原始accounts/FindMy/能力与独立查询。分项status/data/error用于区分失败和未登录；基础读取失败顶层error。前后账户变化丢弃旧profile，返回最终state与姓名/邮箱分项冲突错误。只读工具apple-state.m无需账号密码输入，等待180秒；mutation内部snapshot不聚合网络请求。具体schema、测试及设备工具见模块AGENTS.md/docs/interface.md。

聚合只读工具已部署 `/usr/bin/cazer-apple-state-aggregate-v1`；无需stdin输入，实际queryState返回complete/consistent=true，三个账户域、姓名jack/ma、联系邮箱与转发目标全部取得。主机聚合13场景与原有回归通过。

公共queryState的Find My字段统一为 `icloud.find_my_enabled`，不再放聚合顶层；内部原生snapshot及登录/退出返回state保留原顶层字段。

按用户最新要求，queryState不暴露collection_status/collection_consistent；一次接口调用返回一个汇总JSON。Find My在icloud.find_my_enabled。内部仍核对账户身份，分项失败用该分项status/error表示。旧v1的complete/consistent仅为历史测试记录。

当前聚合工具 `/usr/bin/cazer-apple-state-aggregate-v3` 已真机确认icloud.find_my_enabled=false、姓名/邮箱available，顶层FindMy及两个collection标记均不存在；14个聚合场景及原有回归通过。该改动仅JSON层级，无账户写入。

SCP固定包装 `vendor/apple/tests/device-scp.sh`：`rtk proxy bash vendor/apple/tests/device-scp.sh /tmp/tool /tmp/tool` 上传，`--download <remote-path> <local-path>` 下载，`--recursive` 传目录。顶部DEVICE_*集中配置，与device-ssh.sh换机时一并修改，无环境变量/密码；BatchMode+严格host key。


Sign in with Apple授权工具：vendor/apple公共querySignInWithAppleApps / stopUsingAppleIDForBundleID:appleID，queryState新增apple_settings.sign_in_with_apple/apps/bundle_ids。原生Settings授权列表及确认按钮POST后fresh确认目标消失；不退出整机、不替代成停止email转发/本地cache删除。工具apple-siwa.m经builder构建、device-scp.sh上传、device-ssh.sh运行，stdin query/apple_id 或stop/apple_id/bundle_id。读取原生GET/POST query会话参数，不输出token/URL；schema与边界见模块AGENTS.md。聚合apple-state外层等待现300秒。
