# Apple 原生服务模块

独立的 Objective-C / Foundation 模块。通过 Apple 的系统账户接口工作，宿主负责提供有效的账户权限。不依赖 TrollVNC、RFB、ZXTouch、UI 自动化或命令行交互，也不保存密码。

公共入口：[include/TVAppleServices.h](include/TVAppleServices.h)。`apple.mk` 仅提供可选源码清单，尚未修改 TrollVNC 的构建或协议。

```objc
TVAppleServices *apple = [TVAppleServices new];
[apple queryState:^(NSDictionary *state, NSError *error) { /* 查看独立账户域 */ }];
[apple signOutAppleID:targetAppleID
     localDataPolicy:TVAppleLocalDataRemove
          completion:^(NSDictionary *result, NSError *error) { /* 检查 outcome */ }];
```

接口异步执行，所有实例共用串行工作队列；默认回调在系统后台队列，可通过初始化指定回调队列。结果仅含 JSON 兼容的状态，不含密码、凭据、令牌或系统错误全文。账户名称和标识属于个人数据，宿主自行决定是否显示或记录。

## 范围

已实现账户状态查询、独立 iCloud 退出和整机 Apple ID 退出流程。退出覆盖目标账户的主 iCloud、手机身份 idms、当前媒体账户；保留其他 Apple ID 和历史非活动媒体账户。所有账户预检完成后才开始删除，每次删除前重新核对身份、角色和 Find My 状态。

`signOutICloudAppleID:localDataPolicy:completion:` 只直接删除目标主 iCloud 账户，复用串行队列、预检和最终查询。不会主动删除 idms 或 App Store 账户；系统副作用以返回的实际 state 为准。

`TVAppleLocalDataRemove` 明确选择系统的 DeleteSyncData 或 LoseNonUploadedData 操作（后者会丢弃尚未上传的数据），不合并数据；`TVAppleLocalDataKeep` 明确允许 MergeSyncDataIntoLocalData。不存在隐式默认值。系统未提供所需动作时拒绝退出。Find My 已开启或无法验证时拒绝执行；模块不绕过认证或激活锁。

App Store 登录接口 `signInAppStoreAppleID:password:verificationCodeProvider:completion:` 适配平级 appstorectl 的登录流程。首次 Store 认证被拒且符合二次认证条件时，通过验证码提供器建立 AuthKit 信任，再重试一次 Store 认证。只有全新查询确认目标媒体账户处于活动且已认证状态才返回成功。结果包含实际 `signed_in_domains`，同时反映手机身份和 iCloud 账户变化；不承诺仅修改媒体账户。独立整机 Apple ID 登录仍未提供；iCloud 开通使用下述独立接口。

`TVAppleManualCodeProvider` 把输入密码和验证码分开：先提交账号密码；收到 `challenge_id` 后，宿主自行通过 curl 等方式取码，再调用 `submitCode:forChallengeID:error:` 继续同一次认证。模块不接收验证码 URL，不联网取码、不轮询，也不自动重试验证码。挑战有效期 90 秒，错误的标识或格式不会消费挑战；重复提交、超时或取消后提交会被拒绝。额外的条款、注册或验证方式交互会明确拒绝。登录期间不要在验证码提供器里调用同一模块的账户接口，否则串行队列无法推进。

```objc
TVAppleManualCodeProvider *codes = [[TVAppleManualCodeProvider alloc]
    initWithChallengeHandler:^(NSDictionary *challenge) {
        // 将 challenge 通知宿主；宿主在另一请求中取得验证码并提交。
    }];
[apple signInAppStoreAppleID:targetAppleID password:password
    verificationCodeProvider:codes
    completion:^(NSDictionary *result, NSError *error) { /* 最终认证结果 */ }];
// 后续请求；沿用同一个 codes 实例和收到的 challenge_id。
[codes submitCode:verificationCode forChallengeID:challengeID error:&error];
```

挑战通知不是最终登录结果；`submitCode` 返回 YES 仅表示验证码已交给认证流程，最终成功以登录 completion 为准。原生认证完成或超时后会取消仍在等待的手动挑战。

当前验证码适配使用受信任设备码，挑战标记 `verification_method: trusted_device`；不能提交短信验证码。iOS 15 的适配采用原生 AuthKit JSON 模式，由系统创建、签名并验证受信任设备请求。核心接口和真机排查知识见 [AGENTS.md](AGENTS.md)，实际验证范围见 [docs/validation.md](docs/validation.md)。

## 结果与限制

`succeeded` 表示系统回调及全新账户查询均确认目标登录已退出，`already_signed_out` 表示没有需要处理的目标。`completed_domains` 是系统回调完成的步骤，不能单独用作最终退出依据。

原生删除最多等待 60 秒/账户，最终验证最多等待 5 秒。失败、超时或验证失败在发生删除尝试后返回 `unknown` 和 `TVAppleErrorOutcomeUnknown`，并禁止进程内进一步写操作；仍可查询。未知请求可能稍后完成，调用方应核对状态，不得自动重放。必须确认没有仍在执行的系统操作，再重启宿主以恢复写能力。预检失败返回错误，不执行删除；没有系统级事务，已完成的删除不能回滚。

退出完成仅以系统账户状态验证，不检测、结束或刷新 Settings 页面。

私有接口支持按实际运行时检测。当前原生流程依据 iOS 15.8.8 真机验证；其他版本不保证兼容。root 身份不代替 entitlement；宿主必须具有有效的 `com.apple.private.accounts.allaccounts` 和 `com.apple.itunesstored.private`。登录测试签名还对照上游提供 AuthKit 与原生 Anisette 权限，Apple 框架负责系统认证数据；模块不实现自己的密码存储。测试用签名声明见 `tests/entitlements.plist`，声明本身不代表有效权限。

## 目录

- `include/`：宿主公共 API。
- `src/appleid/`：整机退出编排、Apple ID 邮箱和姓名设置与验证。
- `src/appstore/`：上游登录流程适配、AuthKit 验证码回调与手动提交提供器。
- `src/icloud/`：iCloud 开通、独立退出、Find My 及系统本地数据处理策略。
- `src/common/`：错误、原生运行时后端。
- `private/`：后端注入协议和最小私有选择器声明。
- 平级的 `vendor/appstorectl/`：锁定版本的完整上游源码、MIT 许可与来源。
- `tests/`：可注入后端测试，以及只读真机状态工具。
- `docs/`：接口与验证记录。

后续 iCloud 和 App Store 功能分别扩展 `src/icloud/`、`src/appstore/`。完整上游在平级的 `vendor/appstorectl/`，不会整体混入模块构建。

运行主机测试：`bash vendor/apple/tests/run_tests.sh`。构建真机验证工具：`bash vendor/apple/tests/build_device_probe.sh <输出路径>`。默认仅查询；`--self-test` 使用随机不存在的账户验证幂等空操作及账户集合未改变，不提供实际账户退出命令。

构建实际登录测试工具：`bash vendor/apple/tests/build_device_probe.sh <输出路径> apple-login.m`。请求通过标准输入的一行 JSON 传入（`apple_id`、`password`），不要放进命令行参数、环境变量或仓库。收到 `requires_verification_code` 事件后，通过标准输入再提交一行 JSON（`challenge_id`、`code`）。该工具会真正执行登录，不属于只读测试。

登录适配部分遵循上游 MIT 许可，完整通知保留在 `docs/appstorectl-LICENSE`。

构建真实 iCloud 退出工具：`bash vendor/apple/tests/build_device_probe.sh <输出路径> apple-icloud-logout.m`。标准输入传入一行 JSON，包含 `apple_id` 和显式的 `local_data_policy`（`remove` 或 `keep`）；会实际退出账户。

## 关闭 Find My

```objc
[apple disableFindMyAppleID:targetAppleID password:password
    completion:^(NSDictionary *result, NSError *error) { /* 检查 outcome 和实际 state */ }];
```

使用 Apple ID 密码，经 AuthKit 和 AppleAccount 取得专用关闭令牌，再由 FindMyDevice 关闭本机。已关闭时返回 `already_disabled=true`；成功必须通过全新原生状态查询。当前使用已有设备信任；需要新验证码时明确失败。密码和令牌不保存、不返回。真机关闭及状态验证记录见 `docs/validation.md`。

构建真实 Find My 工具：`bash vendor/apple/tests/build_device_probe.sh <输出路径> apple-findmy-disable.m`。标准输入的一行 JSON 包含 `apple_id`、`password`；不要放入命令行、环境变量或仓库。

## 真机连接与状态查询

固定包装脚本 `tests/device-ssh.sh` 的顶部集中配置主机、端口、用户和已核对的 known-hosts 文件；换机直接修改这些值，无需设置环境变量。脚本关闭本地输入回显并在退出或中断时恢复原终端状态；SSH 使用密钥及 BatchMode，不弹出密码或 host-key 确认。

```bash
rtk proxy bash vendor/apple/tests/device-ssh.sh /usr/bin/apple-state
```

将路径换为设备上实际部署的工具即可。查询调用公共 `queryState:`，返回各账户的 `apple_id`、`domain`、`selected`、`primary`、`enabled_dataclasses`、媒体 `authenticated`，以及 `icloud.find_my_enabled` 和模块能力。Settings 主 iCloud 账户、idms 手机身份与 App Store 媒体账户分别返回；历史非活动媒体记录不会冒充当前登录。非媒体账户的 authenticated=false 不是未登录判据。密码和认证令牌不会返回。

## iCloud 开通

`enableICloudAppleID:password:devicePasscode:verificationCodeProvider:completion:` 使用原生 AuthKit → AASignInFlowController → CoreCDP → 数据服务保存。本机密码先交给 ManagedConfiguration 验证，成功后才构造 CDPLocalSecret；密码仅在本次调用内存中存在。验证码由外部提供器按需单独提交，不在模块轮询。

Find My 必须事先关闭，原生 findMyActivationAction=2 保持关闭。已有主账户也会重新完成原生认证/CDP；仅有账户和 dataclasses 不能证明先前的 CDP 已完成。条款、恢复密钥、其他设备密码等交互分支明确拒绝。未知结果附带可读的实际状态并阻止后续写入。

构建工具：`bash vendor/apple/tests/build_device_probe.sh /tmp/apple-icloud-enable apple-icloud-enable.m`。通过 `tests/device-ssh.sh` 执行；标准输入一行 JSON 包含 `apple_id`、`password`、`device_passcode`，不要把凭据写进命令参数。真机签名需要原生 CDP、profiled-access、keystore.device 与现有认证权限；root 本身不代替这些权限。真机结果和限制见 docs/validation.md。

整机退出集成测试：`bash vendor/apple/tests/build_device_probe.sh /tmp/apple-logout apple-logout.m`，stdin JSON 为 `apple_id`、显式 `local_data_policy`。入口直接调用已有 signOutAppleID，不增加退出实现；会实际删除选定账户，检查三个账户域已退出并输出验证结果。

退出结果的 `warnings` 会保留系统数据动作错误。已验证的 iCloud 原生 YES + Accounts/17 仅在重新查询确认主账户消失且 Find My 关闭后视为账户退出成功，并附 dataclass_action_failed；这不表示所有本地数据处理动作成功。其他失败和超时继续返回 unknown。


退出 iCloud 前会检查 SearchParty 服务。无响应时最多恢复一次，复检通过后才删除；失败则预检返回，不重复账户删除。需要有效 beaconmanager entitlement，并预先部署固定 root 辅助程序：`bash vendor/apple/tests/build_service_recovery.sh <输出路径>`，在设备安装为 bootstrap `/usr/bin/cazer-apple-searchparty-recover`、root:wheel/4755、签名及 trustcache。辅助程序只重启 SearchParty，内置4秒命令期限；结果 `service_recoveries` 说明本次是否恢复。`apple-searchparty-health.m` 可独立验证健康/恢复；详细 RootHide 路径和部署要求见 AGENTS.md。


## Apple ID Settings 姓名

```objc
[apple queryAppleIDNameSettings:targetAppleID
    completion:^(NSDictionary *settings, NSError *error) { /* first_name / last_name / middle_name */ }];
[apple setAppleIDFirstName:@"jack" lastName:@"ma" appleID:targetAppleID
    completion:^(NSDictionary *result, NSError *error) { /* succeeded + fresh settings */ }];
```

同时提供 First、Last，保留原生表单的 Middle Name。保存后重新查询服务端，只有实际三项匹配才成功；相同姓名幂等返回，不重复保存。需要匹配的主 iCloud 和手机身份、有效原生 Settings 权限；未完成的邮箱验证需先完成或过期。真机测试入口 `tests/apple-name-settings.m`，stdin JSON 为 `action=query`/`apple_id`，或 `action=set` 加 `first_name`/`last_name`。接口与实际验证见 docs/interface.md、docs/validation.md。


## 一次查询整体状态

`queryState:` 保留原来的 accounts、capabilities，Find My 统一放在 `icloud.find_my_enabled`，并新增 app_store/icloud/identity 的当前账户摘要，以及 apple_settings.name/email（复用独立姓名/邮箱原生查询）。分项带 status/data：available、not_signed_in 或 error；错误只包含净化的域与码。分项失败时其他已读状态仍保留。独立姓名/邮箱接口继续可用。

查询前后核对选中账户身份；变化时返回最终账户状态，丢弃旧姓名/邮箱并在对应分项报冲突错误。账户基础读取失败则整个调用报错。App Store 与 Settings 不同账号可以分别返回；历史媒体账号不能作为当前登录。详情见 docs/interface.md。只读工具仍是 apple-state.m，通过device-ssh.sh执行，不需要传账号或密码。

汇总只返回各业务分项，不暴露collection_status/collection_consistent等收集标记；一次queryState调用获得一个JSON。


## 通过 Apple 登录的应用

`querySignInWithAppleApps:completion:` 返回原生服务端授权应用的apps与bundle_ids；queryState也包含apple_settings.sign_in_with_apple。`stopUsingAppleIDForBundleID:appleID:completion:` 对明确指定的bundle ID停止使用Apple ID；保存后重新读服务端列表确认目标消失，已经消失则幂等。原生确认按钮、postback、签名与loader执行撤销；不操作UI、不仅删除本地缓存。要求匹配的主iCloud和手机身份，原生表单变化会拒绝而非猜测。

工具 `tests/apple-siwa.m` 通过stdin JSON接收query/apple_id，或stop/apple_id/bundle_id；使用相同device builder、device-scp.sh与device-ssh.sh。SCP脚本默认上传，--download下载，--recursive传目录；换机修改顶部DEVICE_*。实际验证情况见docs/validation.md。
