# Apple 模块开发知识与约束

本文件适用于 `vendor/apple/`。修改前先读公共接口 `include/TVAppleServices.h`、`docs/interface.md` 和 `docs/validation.md`。结论必须区分：真机实际结果、运行时/机器码确认的接口，以及尚未完成的回归验证。

## 模块边界与来源

- 模块是独立的 Objective-C / Foundation 原生账户服务，暂不集成 TrollVNC 的构建、VNC 协议、监听端口或 UI。
- Apple ID、iCloud、App Store 功能分别放在 `src/appleid/`、`src/icloud/`、`src/appstore/`；共享运行时后端和错误处理放在 `src/common/`。
- `vendor/appstorectl/` 是平级 vendor，保留完整上游快照；不要重新放进本模块的 `third_party/` 或添加 `upstream/` 层级。
- 上游固定为 appknox/appstorectl 的 `4b60f16b2066056cc9a9c53da9a61c1aa53fec2f`。适配代码在本模块；不得直接修改上游快照。来源见其 `UPSTREAM.md`，MIT 通知保留在本模块 `docs/appstorectl-LICENSE`。
- 使用 Apple 原生接口。不要使用 ZXTouch、坐标点击或 Settings 页面刷新完成账户操作。

## 权限与运行环境

- 实测环境是 Dopamine / RootHide 的 iOS 15.8.8、arm64 真机。其他系统版本需要重新检查，不能只根据类名相同就宣布兼容。
- root 不等于具备账户 entitlement。必须检查有效权限，不能只检查签名 plist：`com.apple.private.accounts.allaccounts`、`com.apple.itunesstored.private`，登录还依赖 AuthKit 私有/内部客户端权限。
- 测试签名参照上游声明 ADI/原生 Anisette 和 Apple 认证访问权限，见 `tests/entitlements.plist`。这些声明本身不证明运行时有效。
- 由 Apple 框架生成、签名和处理认证请求；不自行实现 Anisette，不添加模块自己的密码或钥匙串存储。
- RootHide 的 shell 路径可能与 Foundation/C 文件访问的原生路径不同。读取临时配置前确认真实路径，不能把 shell 中能看到文件当作原生进程能读到的证明。
- 真机临时执行文件需要正确签名并加入实际 jailbreak root 下的 trustcache。替换同名执行文件可能触发签名/vnode 缓存，诊断时可使用新文件名；不要把一次 killed/137 直接归因为认证接口不可用。

## 账户域与成功标准

- 必须分别查询主 iCloud、idms 手机身份、当前活动媒体账户。历史非活动媒体账户不能代表仍登录。
- `AppleIDAuthentication`、`IdentityServices` 等其他账户类型不能不加区分地当作目标主 Apple ID；删除仅限后端明确选中的目标角色。
- `SSAccountStore` 活动账户缓存必须用 backing account identifier 与全新的 `ACAccountStore` 查询关联。消失的缓存记录不能作为登录成功依据；活动账户缺失必要标识时应返回查询错误。
- App Store 登录成功必须确认目标 Apple ID 的媒体记录同时 `selected=true`、`authenticated=true`，且来自新查询。
- App Store 登录可能影响系统其他账户域。返回实际 `signed_in_domains`，不得承诺仅修改 App Store，也不得把媒体登录成功说成 iCloud 已启用。
- App Store 测试完成时，目标媒体账户活动且已认证，尚无选中的 iCloud 主账户。后来用户在 Settings 手动完成独立 iCloud 登录；不能将后者算作模块的登录成功。
- 整机退出成功只看目标主 iCloud、idms、活动媒体记录是否已退出，不检查、重启或刷新 Settings 页面。

## 独立 iCloud 退出

- 公共接口 `signOutICloudAppleID:localDataPolicy:completion:` 位于 `src/icloud/TVAppleICloudSignOut.m`，复用共用串行编排。目标仅为指定 Apple ID 的 selected+primary iCloud 记录，成功不要求该账号的媒体/idms 退出。
- 不主动操作其他账户域，但原生系统可能产生副作用；返回全新 state。目标 iCloud 已不存在时为幂等成功。
- 删除前重新查询系统动作集合并比较静态动作名和 destructive 标记；动作集合变化时拒绝执行旧动作。

## 整机 Apple ID 退出

- 先对所有目标账户完成预检，再依次删除主 iCloud → idms → 活动媒体，最后重新查询验证。
- 保留其他 Apple ID 和历史非活动媒体账户；不得使用无目标限制的“退出所有账户”替代此流程。
- 本地数据策略必须显式传入。`TVAppleLocalDataRemove` 只选系统提供的 `ACDataclassActionDeleteSyncData` 或 `ACDataclassActionLoseNonUploadedData`（真机 Notes 提供后者，会丢弃未上传数据）；不能合并。`TVAppleLocalDataKeep` 才允许 `ACDataclassActionMergeSyncDataIntoLocalData`。
- 必须按实际动作名称精确匹配；缺失、含糊或动作集合改变时拒绝操作。不能靠名称子串或 `isDestructive` 猜测策略。
- Find My 已开启或无法确认时拒绝退出；不绕过激活锁。每次删除前重新核对角色、账户身份和已启用 dataclass。
- 删除后的失败可能代表部分完成；不存在可回滚的系统事务。必须报告已完成步骤和实际状态。

## 登录密码与验证码分离

- 外部先提交 Apple ID 和密码。只有原生流程实际需要验证码时，提供器才发布 `requires_verification_code` 挑战。
- 使用 `TVAppleManualCodeProvider`：外部自行 curl 取码，然后在后续请求中调用 `submitCode:forChallengeID:error:`，继续同一次认证。
- 模块不能保存验证码 URL，不能联网取码、轮询、读取旧码基线，也不能把验证码拼到命令行参数或环境变量里。
- 挑战含唯一 `challenge_id`、有效期和验证码类型。当前登录适配使用受信任设备验证码；短信验证码不是同一种输入。
- 输入格式为六位 ASCII 数字，保留前导零。错误标识/格式不消费挑战；重复、取消、过期或认证结束后的输入拒绝接受。
- `submitCode` 的 YES 只表示交给流程，不表示 Apple 接受验证码。最终结果仍由登录 completion 和全新账户查询决定。
- 所有账户操作共用串行工作队列。验证码提供器不能为取码再次调用同一模块的账户方法，否则会阻塞正在等待的登录。

## Store 与 AuthKit 原生流程

- 基本顺序是 Store 认证 → 必要时一次 AuthKit 信任建立 → 一次 Store 重试 → 全新账户验证。
- `SSAuthenticationContext.contextForSignIn` 取 mutable context；设置账号、password/initialPassword、允许创建和活动账户。`promptStyle=1` 强制真实认证，禁止自动 retry；不要从旧账户复制 altDSID。
- `SSAuthenticateRequest.startWithAuthenticateResponseBlock:` 回调为 `(response, NSError *)`。type 4 且没有错误才是认证成功；type 1 的 `SSServerErrorDomain/-5000` 才允许尝试信任建立，不能直接断言密码错误。
- `AKAppleIDAuthenticationController.authenticateWithContext:completion:` 回调为 `(NSDictionary *, NSError *)`。在回调内立即提取所需信息；不得等 autoreleased 对象释放后再猜测其类型。
- AuthKit 接受原生 `AKAppleIDAuthenticationCommandLineContext`。之前的自定义 context 子类尝试出现 `-7085`；正式适配保留原生类型，通过进程内、仅限本模块实例的回调适配处理输入。
- 不在 Apple daemon 中安装 hook。未归属本模块的 context 必须调用保存的原始 IMP；先验证所有所需 ABI，再安装适配。
- 方法编码中的 `@` 只说明是对象，不能证明对象具体是字符串、数字、字典，也不能证明 block 的参数顺序。

## 本次登录排查得到的关键细节

1. **getter 不是挑战通知。** iOS 15 的 `secondFactorCode` getter 只是读取 ivar。不能把它改成主动取码，否则会提前触发输入；正式代码不替换该 getter。
2. **真正的基础二次认证输入会绕过 `_prompt…`。** `presentSecondFactorUIWithCompletion:` 会直接调用 `AKReadLine`；只替换 `_promptForVerificationCodeWithSecureEntry:forTrustedNumber:` 不足以移除终端输入。
3. **基础回调验证码是 NSNumber。** 原生代码将六位输入转换为 NSNumber，再调用 `(NSNumber *, NSError *)` completion；`setSecondFactorCode:` 同样接收 NSNumber。ServerUI JSON 请求中的验证码仍是六位 NSString，不能混用两层类型。
4. **默认 XML 模式会遇到只有提示框的响应。** 实测 `RUIObjectModel.allPages` 为 0、存在 `primaryAlert`，有发送新码/短信按钮。命令行解析器直接查找首个 page，因而输出 `missing page` 并返回 `-7014`。
5. **原生 JSON 模式可读取当前响应。** `initWithVerificationType:1` 的真机对照请求取得 JSON 二次认证数据，并进入验证码步骤；不是单纯把等待间隔拉长。
6. **JSON 内置分支默认是短信。** 观察到它向 `/auth/verify/phone/securitycode` 提交 `phoneNumber`、`mode` 和 `securityCode`，用受信任设备码时出现 `-7039`。受信任设备码应提交到 `/auth/verify/trusteddevice/securitycode`，body 只含 `securityCode.code`。
7. **仍由原生框架处理请求。** 正式适配通过 `AKCommandLineUtilities.mutableJSONRequestForPath:` 创建请求、configuration 的 resource load delegate `signRequest:` 签名，再调用原生 `_verifySecondFactorCodeWithRequest:completion:`。不要自造认证响应或凭据。
8. **ServerUI completion 三个对象的顺序必须正确。** 已观察的 block 签名为 `(NSHTTPURLResponse *, NSDictionary *, NSError *)`；不能把响应、body 的顺序调换。原生 verifier 会转交实际 HTTP 响应，避免把空 body 当作没有响应。
9. **客户端错误不证明没有服务端副作用。** 受信任设备接口对照测试仍收到一次客户端 `-7014`，但随后 Store 认证已成功，独立查询确认媒体登录。失败后必须查询实际状态，不能自动盲目重放。

`-7014`、`-7039` 是私有错误，以上只是本次具体调用路径的观察，不是可靠的全版本错误枚举。尤其不能将所有 `-7014` 都等同于 missing page，或将所有 `-7039` 都等同于验证码错误。

## iCloud 原生登录排查（历史，后续成功见末节）

- 2026-10-07 真机：已登录 App Store 后，用户仍需在 Settings 输入 Apple ID 密码，再输入本机解锁密码，才能完成 iCloud 登录；用户未遇到新的 2FA 输入。
- 原生成功流程为 `AASignInFlowController` 登录并更新账户 → preflight save → CoreCDP 状态验证及本机密码输入 → dataclass enablement/save → 登录 completion。系统日志明确记录 `Validating iCDP succeeded!` 和 `AAUISignInController signed in with authentication results successfully!`。不可跳过 CDP 来宣称完整成功。
- 本次 CoreCDP 日志记录 local secret prompt、silent escrow recovery、`joinAfterRestore succeeded`。本机解锁密码属于 CoreCDP 本地验证输入，不等同于 Apple ID 密码或受信任设备验证码。
- 当前工具使用真实 AuthKit 结果调用原生 iCloud flow，但此前在 AppleAccount 的 `InitializeAbsinthe` 阶段报 `com.apple.AppleAccount.Error/-4403`（NAC session 初始化失败），随后返回 `com.apple.appleaccount/400`；未到 CDP 密码步骤。Settings 成功流程没有同样的初始化失败记录。签名上下文/权限差异是待验证线索，不能把 -4403 当作已查明的全版本错误定义或直接归咎于密码/2FA。
- 手动完成后，全新模块查询确认目标主 iCloud 账户及数据服务启用。最初 dataclass 查询显示 Find My 关闭，但后续 `FMDFMIPSharedStateManager.fmipActive=true`，且删除被系统 FMIP 检查拒绝；不能据 dataclass 宣称 Find My 已关闭。此结果验证设备状态，不证明模块 `enable_icloud` 已实现或成功。
- 读取系统历史日志时，`OSLogEventProxy` 可能对实际存在的 getter 返回 `respondsToSelector:NO`；本机诊断通过 runtime 方法检查后可读取事件。日志导出只保留时间、进程、子系统、静态 format 和错误 domain/code，不能导出完整 composed message、请求内容或认证令牌。

## 异步、超时与验证

- completion 只能执行一次。共享验证码 ticket 必须兼容多个等待者，不能用一次性 semaphore 消费结果导致其他等待者超时。
- 已验证验证码只在同一次挑战内共享；不能因 getter 重读而再取码，不能自动向 Apple 重试已被拒绝的验证码。
- 原生账户删除等待上限 60 秒/账户；Store 尝试 120 秒；提供器准备 30 秒；AuthKit 180 秒；手动挑战 90 秒；最终状态验证 5 秒。
- 超时不意味着 Apple daemon 的操作已被取消。`unknown` 后进程内禁止进一步账户写操作，仍允许只读查询；确认没有未完成请求后才能恢复写能力。
- 原生认证完成/超时后关闭挑战、取消待提交输入并释放短期验证码/密码引用。晚到回调不能重新提交验证码或落回终端读取。
- malformed 回调、认证成功与错误矛盾、最终状态不可读，都不能按成功或正常拒绝处理。

## 开发、测试与保密

从 TrollVNC 目录执行：

```bash
rtk proxy bash vendor/apple/tests/run_tests.sh
rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-state
rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-login apple-login.m
```

- 主机测试检查编排、失败状态、数据策略和实际回调适配；不能替代未信任设备的完整二次认证真机回归。
- `apple-state` 默认只读；`--self-test` 用不存在的目标做幂等空操作。`apple-login` 会真实登录。
- 有效性记录写到 `docs/validation.md`，说明是否走过 bootstrap，还是利用已经建立的信任直接 Store 成功。
- 当前验证边界：受信任设备接口对照测试后，Store 登录及目标媒体账户认证已在真机确认；正式适配的请求签名、回调和响应转交有主机回归覆盖，但尚未在全新未建立信任的设备上完整复测 bootstrap。后续不得把这两项合并宣称已验证。
- 密码、验证码、取码 URL、Apple 认证令牌和原生 error userInfo 不进仓库、不输出日志。临时配置用私有目录和 0600 文件，读取/测试后删除。
- 调试只记录必要的 selector、类型、状态码、字段结构，不打印认证请求 body/headers 的真实内容。调试代码标记唯一前缀，完成后清理。
- 所有本地 shell 命令遵循上级 RTK 规则；SSH/SCP 使用 BatchMode，文件操作使用非交互 flags。

## Find My 密码验证

- 关闭 Find My 必须使用 Apple ID 密码认证。AuthKit 返回的 AKPassword 绑定到主账户副本，交给 AAFMIPAuthenticateRequest 获取专用 fmipWipeToken；不保存副本凭据、不离线修改 Find My 标记。
- AARequest.performRequestWithHandler 的三个参数是 request、AAResponse、NSError。HTTP 响应从 AAResponse.httpResponse 取得；不能将第一个参数当作 BOOL 或 NSHTTPURLResponse。GitHub 反编译 AARequest 的 _handleDataTaskCompletionWithData:response:error: 明确调用 handler(self, parsedResponse, error)。
- AAFMIPAuthenticateResponse 的令牌来自 tokens.mmeFMIPWipeToken，DSID 来自 appleAccountInfo.dsid；成功响应可能没有 fmipUrl。真机探针已取得令牌，不代表正式关闭完成。
- 来源：EthanArbuckle/iPhone17-1_18.2_22C152_Restore，固定 e26ed4563f78871c59d2d96856756a65d62517e5，AppleAccount/AARequest.m、AAFMIPAuthenticateResponse.m；AppleAccountUI/AAUIDeviceLocatorService.m；FindMyDevice/FMDFMIPManager.m。这是 iOS 18 的反编译线索，仍需 iOS 15 真机确认。

- 2026-10-07 真机正式工具第一次完成密码验证并取得令牌，但 disableFMIPForAccount:pairedDeviceWithUDID:nil 被 daemon 拒绝，静态日志为 Could not find paired device with UDID，FindMyDevice error 1。这个配对设备接口不能用 nil 代替本机；本机采用 Settings 的 disableFMIPUsingToken:inContext:completion:，此机 context=1。

- 本机关闭已实测：原生关闭回调完成后 daemon state=3/error=nil、fmipActive=false、Settings cache available=true/enabled=false。正式工具修正状态解析后返回 succeeded/already_disabled=true/find_my_enabled=false。只接受观测过的 0/1（开启）和 3（关闭），2/4/其他状态或任何 error 均拒绝；不要再使用 state<=2 判断有效。主机回归直接覆盖正式 reader 和重复回调。最终修正版尚未重新从开启状态跑完整流程，不能混同于上述两段验证。

- 独立 iCloud 退出已在已登录真机实际执行 remove 策略。首次工具结果 unknown，但全新账户查询确认主 iCloud 消失、idms/活动已认证媒体仍在、Find My 关闭；系统日志记录 iCloud account deleted。当时未采集回调元数据；本次同症状的 YES+Accounts/17 已定位，见末节。不能将相关 CloudDocs 4097 错误当作确定原因。失败结果附带 fresh state 和 target_signed_out（可读时），保持 unknown 和写入栅栏。之后确认状态再运行新工具，返回 succeeded/already_signed_out=true；两段验证不能说成首轮正常回调完成。
- 通用 SSH 入口：tests/device-ssh.sh。仅修改顶部 DEVICE_HOST/PORT/USER/KNOWN_HOSTS；不使用环境变量配置，不写密码。运行 rtk proxy bash vendor/apple/tests/device-ssh.sh /usr/bin/apple-state；登录/退出工具同样传可执行路径，敏感 JSON 走 stdin。脚本保留终端原状态并在退出/中断时恢复，不允许用参数传密码。

## iCloud 开通工具（2026-10-07 已验证）

- 公共 `enableICloudAppleID:password:devicePasscode:verificationCodeProvider:completion:`，实现 `src/icloud/TVAppleICloudEnablement.m`，共享队列/未知结果写栅栏在 TVAppleServices.m。工具 `tests/apple-icloud-enable.m`，stdin JSON 增加 device_passcode；不持久化凭据，不自行请求认证 HTTP，不做 UI 操作。
- 原生 AuthKit 结果 → AASignInFlowController，delegate/cdpUIProvider 为 Foundation 对象，自动保存账户；callback `(BOOL, account, NSError)`。成功后再查询主 iCloud、非空 dataclasses、Find My=false。
- CDPLocalDevice.hasLocalSecret → MCProfileConnection.sharedConnection.unlockDeviceWithPasscode:outError: → unlockScreenTypeWithOutSimplePasscodeType: → CDPLocalSecret.initWithValidatedSecret:secretType:。只有验证成功才交付密码；simpleType=-1 对应 complex=3，非负对应 simple=2；其他值拒绝。
- 已有主账户/dataclasses 不能跳过 CDP。原生 CDP 可把 local UI 输入错误当 non-fatal，照样保存账户，因此必须让 provider.failure 覆盖原生 success。重复/关闭后的本机密码挑战拒绝，结束后释放 passcode。
- 保持 Find My 关闭：预检拒绝 enabled/unknown，findMyActivationAction=2；最终再次验证关闭。恢复密钥、beneficiary、EDP、其他设备密码、条款、多 ICSC adoption 明确拒绝，不做加密数据重置。EDP continuation 是成功通知，拒绝时不得调用。
- 本机有效权限需要 com.apple.cdp.statemachine、com.apple.managedconfiguration.profiled-access、com.apple.keystore.device 以及现有 AuthKit/账户/Absinthe 权限，见 tests/entitlements.plist。root 不等于 keystore 权限。
- 真机首次创建主账户及 dataclasses，但本机密码验证失败，返回 unknown，不能认定 CDP 完成。补 keystore.device 后新进程再次执行原生认证/CDP，返回 succeeded/already_enabled=true，Find My=false。日志显示本机 secret 已接收、silent recovery 成功并保存账户。没有新增 2FA 提示。这是两阶段真实验证，不是最终版本从全退出状态的一次全流程回归。
- 61 项主机检查通过，包含生产密码 provider 的简单/复杂/拒绝/重复/超时关闭与恢复分支；arm64 iOS15 编译签名通过。其他 iOS 版本和全新未信任账号尚未验证。
- 参考：[CDPToolFakeUIProvider](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/e26ed4563f78871c59d2d96856756a65d62517e5/System/Library/PrivateFrameworks/CoreCDP.framework/CDPToolFakeUIProvider.m) 的原生验证顺序；[RecoveryKey UI protocol](https://github.com/MTACS/iOS-17-Runtime-Headers/blob/master/protocols/CDPRecoveryKeyUIProvider.h) 明示恢复回调 BOOL/NSError。实际选择器已在 iOS15 设备确认，不能将 iOS18 反编译当作全版本 ABI 保证。

## iCloud 删除回调的 YES + error（2026-10-07 排查修复）

- 复现回调及时到达，原生 BOOL=YES，但 NSError domain=com.apple.accounts/code=17；不是超时或 BOOL/NSError ABI 错误。Xcode Accounts/ACError.h 定义 17 为 ACErrorDeniedByPlugin。
- 同时段静态日志明确：Plugins did not deny removal → account deleted → Failed to perform dataclass actions (17) → Account removed。此处账户删除和数据动作错误共存，不能用 ok&&!error 一概判删除失败，也不能把所有 error 都忽略。
- 仅主 iCloud + native YES + 确切域码17，收到回调后全新读取确认目标主账户及旧identifier消失、Find My=false，才认定账户退出成功。warnings包含domain=icloud/kind=dataclass_action_failed/error_domain/code；这不保证每项本地同步数据已清理。读失败/仍有账户/FindMy开启仍unknown+写栅栏，但保留该warning。false/其他域码/超时无此特判。
- 源码在 src/common/TVAppleNativeBackend.m，编排在 src/appleid/TVAppleServices.m。测试直接调用生产后端的 removePreparedAccount，旧代码确定失败后修复；补服务成功/unknown的warning传播，总71项主机检查。诊断stderr已从正式代码删除，不保留native userInfo。

- 本次修正已在真机实际删除验证：一次调用 completed_domains=[icloud,identity,media]、succeeded、选中账户为空，保留 Accounts/17 dataclass_action_failed warning。清理动作完整成功不在该结论内。
- 多次退出/开通循环还暴露了独立 SearchParty 服务挂起：日志 senderImagePath 对应 SearchPartyAccountNotificationPlugin，canRemoveAccount 等 removeLocalAccountDataWithCompletion 无回调，60秒后账户仍在。复用 defaultStore 对照无效，已撤回。测试操作者用 launchctl kickstart -k system/com.apple.icloud.searchpartyd 恢复；当时正式模块尚未自动恢复daemon；现已补充删除前健康检查和一次恢复，见下节，不绕过FindMy。恢复后一次整机退出通过。以后要将这种真超时和 YES+17 分开，保留unknown/fence，不盲重放。

- 修复后完整登录复测：全退出 → cazer-apple-login-v5 成功，无新2FA；其后全新查询该路径仅媒体账户。cazer-apple-icloud-enable-v4 从无主账户状态一次 succeeded/already_enabled=false，最终icloud/identity/media均选中，Find My关闭。不能根据Store返回推断Settings/CoreCDP状态，要逐域查询。设备按本次要求保持iCloud已开通状态。

## SearchParty 挂起自动恢复（2026-10-07）

- `src/icloud/TVAppleSearchParty.m` 在 iCloud 删除的预检中，只读检查原生 SearchParty XPC 回复。5秒无响应才调用固定 root helper 恢复一次，5秒恢复期限，复检10秒。复检失败返回预检错误，不提交账户删除；已提交删除仍沿用60秒期限与 unknown/fence，不能重放删除。
- 有效 entitlement `com.apple.icloud.searchpartyd.beaconmanager` 必须存在；root 身份不能代替。回复只表示服务当前能响应，不保证后续所有插件调用必成功，继续保留账户最终验证。
- Native `SPBeaconManager.proxy` 要在 manager.queue 取；`FMXPCSession.proxy` 内部同步到 session.serialQueue，不能在它的 serialQueue 取（会断言死锁）。正式健康检查使用 FMXPCSession 和独立 adapter 队列，start/proxy/invalidate 均不阻塞账户工作线程。
- 不调用 `SPBeaconManager.start`：它会启动健康检查不需要的 beacon/activation-lock 通知。iOS15 原生 invalidate 后释放 manager 曾造成 localActivationLockInfoChanged 指向已释放对象。正式代码仅保留一个 process-lifetime owner 取得 Apple 原生 serviceDescription，再创建有限期限 XPC session，只调用 beaconingStateWithCompletion，不读写 beacon 数据。
- root helper 源码 `src/icloud/TVAppleSearchPartyRecovery.c`，构建 `tests/build_service_recovery.sh <输出>`。部署到 bootstrap `/usr/bin/cazer-apple-searchparty-recover`，root:wheel、4755、正确签名及原生路径 trustcache。只接受零参数，只执行 `launchctl kickstart -k system/com.apple.icloud.searchpartyd`；无 shell、sudo、密码、外部服务名、环境变量配置。
- RootHide 原生路径依据 loader image 的 `.jbroot` 链接解析，不硬编码随机目录。helper 从自身原生 executable 路径定位相邻 launchctl，校验文件 root-owned/non-writable、受保护父目录（root 或 Apple _installd），清空 exec 环境。helper 的 root 父进程保留调用者 real UID，子进程才切到 root 执行；父进程4秒内超时杀死并有限回收子进程，避免 mobile 无权杀 root launchctl。库外层清理也有期限。
- 成功恢复元数据 `service_recoveries=[{service:searchpartyd,stage:before_account_removal}]`；正常健康流程为空。辅助程序缺失/权限不符合/恢复失败时返回明确错误，不进入删除。独立 iCloud 和整机退出共用此预检。
- 真机 SIGSTOP 精确 SearchParty PID 后，模块自动恢复一次，整机退出一次 succeeded、completed_domains=[icloud,identity,media]、verified_all_domains_signed_out=true，FindMy=false；正常再次 Store 登录→iCloud 开通→完整退出也成功，recoveries为空。最终带 root 内部期限的 helper 另跑故障健康测试 ready=true/recovered=true。
- 主机测试覆盖恢复失败、不可用、不重复恢复、复检失败、代理队列、超时/重复/迟到回调、阻塞代理，以及实际 helper 监督函数的成功/非零退出/卡住子进程 kill+reap。当前仍有 Accounts/17 数据动作 warning：账户退出已验证，不保证所有本地数据动作成功。


## Apple ID 联系邮箱接口排查（2026-10-07；早期发现，完成情况见下节）

- 用户选择 Apple ID Settings 的联系邮箱，不是 Hide My Email。新增地址、验证码和转发类型/目标由外部提供；不能自行生成地址或取码。
- 已实现 `queryAppleIDEmailSettings:completion:`，代码 `src/appleid/TVAppleEmailSettings.m`。iOS15 `fetchUserInformationForAltDSID:completion:` 返回 NSDictionary，交给 `AKUserInformation.initWithResponseBody:` 解析；不要当作缓存对象直接调用属性。reachableEmails 必须存在且为字符串数组，不能将缺字段当作空列表。完成后再次核对主身份 identifier/username，重复/迟到回调忽略。
- 真机 fresh response 可没有 accountName/primaryEmailAddress；这两个返回 null。`forwardingEmail` 来自 AuthKit `forwardTo`，不能冒称 iCloud Mail 全部收件转发。
- `AKAccountManager.setReachableEmailAddresses:forAccount:` / `setForwardingEmail:forAccount:` 及 `updateUserInformationForAltDSID:userInformation:completion:` 是本地缓存更新，不证明服务端添加/转发成功。AAUIAuthKitUpdateReachableEmailsHook 在服务端 RUI 完成后才更新缓存。
- Settings 个人信息入口是 `AAPersonalInfoUIRequest.initWithGrandSlamAccount:accountStore:`。由主 iCloud 获取关联 GrandSlam，AuthKit context 绑定其 alternateDSID，原生 `getServerUILoadDelegateWithContext:completion:` 得到 signer，service token 为系统 GrandSlam 的 com.apple.gs.appleid.auth token，调用 `signRequest:` 后 RUILoader 得到 HTTP200。token 不输出、不保存；未签名为401。
- `AAAppleIDSettingsRequest.urlRequest` 默认 forceGSToken 路径可能无限等待续 token；诊断设置 forceGSToken:NO 并用原生 signer，不将该无期限路径带入生产队列。
- `AAAddEmailUIRequest` 是创建 @icloud.com 免费邮箱：表单 suffix=@icloud.com、下一动作 /setup/iosbuddy/ui/addfreeemailpage，不是新增任意联系邮箱。不要使用它实现本任务。
- 真机个人信息 RUI inlineScript 的 toggleReachableAtEditing 暴露原生动作 `/appleid/settings/account/manage/email/alternate/add`，还有 verifyAlternateEmail / deleteAlternateEmail。该发现阶段仅读取表单/静态动作，没有提交邮箱或验证码。后续正式操作结果见下节。
- 正确联系邮箱新增 GET 表单已真机 HTTP200：字段 id=address、class=editableText，服务端提供 POST 动作 `/appleid/settings/account/manage/email/alternate/add/verification`。该发现阶段尚未提交；后续正式适配采用原生 RUI postback/loader/signing 与外部邮箱验证码，成功后 fresh reachableEmails 验证，不只更新缓存。


## 联系邮箱新增与全局隐藏邮箱转发（2026-10-07 已实际执行）

- 独立代码 `src/appleid/TVAppleEmailActions.m`，公共 beginAddingContactEmail / verifyContactEmailChallenge / setSignInWithAppleForwardingEmail。新增和邮箱验证码分为两个请求、同一 Services 实例；300秒 challenge，仅准备好请求才消费一次，错标识/格式/表单不消费。过期或完成释放内存中的原生 signer/model，不持久化 token/代码，不自动重发或取码。
- 新增表单字段 address；验证码是 RUIPasscodeView id=verificationInfo.answer、POST `/appleid/settings/account/manage/email/alternate/verification/put`，不是右上按钮，也不是受信任设备2FA。native postbackData 保留 serverInfo；Content-Type 必须 application/x-plist（RemoteUIController 的默认值），缺少时实测415。
- RUILoader 的异步收尾能清空/覆盖 model.sourceURL；动作解析固定使用保存的原生 origin，并精确限制路径/同源HTTPS。不能把未准备成功的验证码请求当成已提交或消费挑战。
- Foundation 进程通过 loadResourcesForObjectModel 捕获原生模型，alert 按未确认结果处理并移除内存中的 presentation primaryAlert；没有 setter 的 iOS15 用已确认 _primaryAlert 的 KVC，未知结构立即取消，不等待 UIKit 提示框。必须收到 terminal didFinishLoadWithError 且model/HTTP200齐全才完成；模型先到后的error不能丢弃，超时即使已有model也unknown/fence。重复/late回调关闭后忽略。
- Settings个人信息表单没有全局forward入口。正确路径从 AKURLBag.initWithAltDSID 的 privateEmailManageURL 取得：本机 HTTPS gsa.apple.com `/appleid/settings/account/manage/email/private`，table id=privateEmailView，同时列App隐藏邮箱和公共“转发到”。公共GET精确 `/appleid/settings/account/manage/forwardemail`，不是某个App的 `/security/apps/email/private/<app>`。
- 公共转发表单单页，行class=label/radioGroup=forwardToEmail，label匹配目标、value使用服务端原始值；save name=ak-button、ak-action=read、POST精确 `/appleid/settings/account/manage/forwardemail/put`。不能用路径含forward或通用radioGroup猜接口，不能触发matterhornUpsell。fresh forwarding_email 匹配才成功；已匹配返回already_configured=true，不提交POST。
- 正式工具v2新增并验证联系邮箱 succeeded，fresh reachableEmails确认目标；v4公共forward保存 succeeded/already_configured=false，fresh forwarding_email确认新目标。不是Vinted单独开关，不是iCloud Mail。实际App发信→目标收件箱投递尚未验证。
- CLI `tests/apple-email-actions.m`，同一个进程 stdin多行 action=begin/verify/forward/query；详细字段见docs/interface.md。主机新增 EmailActionsTests 测生产 postback/终止observer/超时结果/challenge消费与过期/精确转发表单拒绝/共享写栅栏，arm64 iOS15编译签名。最终微调版本的新增写流程未另发验证码重跑；精确记录分段验证。
- 最终v5真机幂等forward succeeded/already_configured=true；独立query再次确认目标reachable_emails与forwarding_email。当前可用工具 /usr/bin/cazer-apple-email-actions-v5，开发诊断/旧动作工具已清理；未重发验证码测试最终版本新增POST。


## Apple ID Settings 姓名工具（2026-10-07）

- `queryAppleIDNameSettings:completion:` 与 `setAppleIDFirstName:lastName:appleID:completion:` 位于 `src/appleid/TVAppleNameSettings.m`，公共门面仍是 TVAppleServices；共用全局串行队列/unknown 写栅栏。
- 邮箱与姓名共用 `TVAppleNativeSettingsSession` 原生签名/RemoteUI transport。私有内部接口为 `private/TVAppleSettingsSession.h`；未完成的邮箱 challenge 必须先完成/过期，不能丢弃会话来开另一个操作。
- 真机 GET 个人信息 `/appleid/settings/account/manage` 的 clientInfo 提供 firstName/lastName/middleName/accountName。全新查询验证主 iCloud/idms 身份与 server accountName；不使用本地显示名缓存。
- 跟随服务端广告的 `/appleid/settings/account/manage/name`，字段为 firstName/middleName/lastName（editableText），保存仅接受 ak-button/read POST `/appleid/settings/account/manage/person/name/put`。Middle Name 从原生表单读出并原样提交保留；不要清空或遗漏。继续使用原生 postbackData、application/x-plist、AuthKit signer 和终止回调约束。
- 参数必须显式提供 First/Last，非空白、不含控制字符、各最多128个UTF-16单位，支持Unicode/内部空格；不自动改大小写/去空格。保存后重新查询三项，任何未确认结果按 unknown 栅栏处理；已相同则不POST。
- 真机工具 `tests/apple-name-settings.m`：`rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-name-settings apple-name-settings.m`，部署/trust后通过device-ssh.sh运行。stdin JSON action=query/apple_id，或 action=set/apple_id/first_name/last_name；无环境变量和凭据存储。
- 该机正式保存 jack / ma 成功，Middle为空保留；独立进程重新查询及同值幂等测试通过。尚未验证新认证提示/其他iOS。`tests/EmailActionsTests.m`覆盖正式姓名postback、fresh验证、幂等、输入/共享写栅栏。
- 用户已确认隐藏邮箱转发的实际邮件投递正常；这是用户执行的投递验证，不是模块自动发信/查收。

- 最终姓名工具部署 `/usr/bin/cazer-apple-name-settings-v2`；CLI总等待300秒，覆盖prepare30秒与多个transport40秒的累计期限。独立审查未见P1/P2；已补POST后身份改变→unknown与pending邮箱challenge不被姓名操作丢弃的回归，全部通过。


## queryState 整体状态聚合

- 公共queryState保留accounts/capabilities/schema_version=1，Find My统一放在icloud.find_my_enabled（不再放聚合顶层），在全局Worker上调用 `src/appleid/TVAppleStateAggregation.m` 的同步后端聚合；不在Worker内调用异步公共query接口，否则会死锁。
- 新增app_store/icloud/identity摘要(status/account)，apple_settings(status/apple_id/name/email)。独立姓名/邮箱原生查询继续保留并复用相同backend。
- name/email分项status=available/data原生查询结果，not_signed_in/data=null，error/data=null/error只有净化domain/code。分项失败保留其他数据；基础或最终snapshot失败顶层error，不能返回虚假未登录。查询不设置unknown写栅栏。
- Settings目标取唯一选中idms，否则唯一主icloud；多个身份或cloud/idms不一致保守conflict，不猜账号。AppStore可不同账号；历史未选中媒体不能代表登录。只有媒体时不发起姓名/邮箱查询；原生查询各自要求仍有效（如姓名需要匹配cloud/idms）。
- profile查询前后再次snapshot核对selected identifier/domain/apple_id/primary；变化时返回最终账户，丢弃旧profile并在name/email分项报冲突错误。不是原子系统事务。不改变登录/退出内部snapshot及completion state，不把网络profile放进mutation最终验证。
- `tests/StateAggregationTests.m`覆盖聚合成功、分项失败/不支持、未登录/仅媒体、不同媒体账号、目标冲突/响应错账号、前后身份变化与基础读取失败。`tests/apple-state.m`无需输入，外层等待180秒，覆盖姓名/邮箱原生期限；查询相比原来本地snapshot更慢。

- 聚合真机正式工具 `/usr/bin/cazer-apple-state-aggregate-v1` 一次只读查询返回complete/consistent=true，AppStore活动已认证、icloud/idms选中、FindMy=false、name=jack/ma、email及forward均available；没有提交写操作。新增13个聚合主机场景及原有回归全部通过，独立审查未发现P1/P2。错误/切换身份分支仅主机覆盖，未在真机制造故障。

- Find My字段层级按用户要求归属icloud：公共queryState只返回icloud.find_my_enabled，取值保留真实native结果；未登录icloud仍保留该字段，不根据登录状态伪造false。内部snapshot及mutation返回state维持原顶层键，避免改变退出/登录验证逻辑。

- 按用户最新要求，queryState不输出collection_status或collection_consistent收集标记。一次调用返回一个汇总JSON，各业务分项自己的status/error说明查询结果；必要的前后身份核对留在内部。前文complete/consistent是旧v1验证记录，不是当前schema。

当前聚合工具 `/usr/bin/cazer-apple-state-aggregate-v3` 已真机确认icloud.find_my_enabled=false、姓名/邮箱available，顶层FindMy及两个collection标记均不存在；14个聚合场景及原有回归通过。该改动仅JSON层级，无账户写入。


## 固定 SCP 入口

`tests/device-scp.sh` 与device-ssh.sh一样在顶部填写DEVICE_HOST/PORT/USER/KNOWN_HOSTS，不用环境变量、不存密码，密钥+BatchMode+StrictHostKeyChecking。上传 `rtk proxy bash vendor/apple/tests/device-scp.sh /tmp/tool /tmp/tool`；下载加 `--download`，目录加 `--recursive`。路径各自引用保留空格；下载会覆盖明确指定的本地目标。两个脚本换机时都更新顶部配置。仅传输文件，安装/root/trustcache仍经device-ssh.sh完成。


## Sign in with Apple 应用授权

- 代码src/appleid/TVAppleSignInWithApple.m。公共querySignInWithAppleApps查询apps/bundle_ids，stopUsingAppleIDForBundleID:appleID撤销明确bundle；queryState聚合apple_settings.sign_in_with_apple。同一SettingsSession与Worker/unknown写栅栏，不递归公共异步查询。
- 真机GET /appleid/settings/account/manage/security/apps，单页connectedAppView/connectApplicationSection，row.id是原生bundle，url客户端标识为bundle+.app。已看到Vinted的lt.manodrabuziai.fr，client_id=lt.manodrabuziai.fr.app。严格校验本次原生app schema；缺表结构/歧义/其他web/service形状不猜bundle也不当空列表。
- 移除最后一个授权后，iOS15实际返回connectedAppView下唯一匿名空分区：attributes为{}，rows为[]，不再包含connectApplicationSection。仅此已确认结构也解析为空列表；未知table/分区、有行的匿名分区仍拒绝。旧版本因此在实际撤销成功后误报unknown；不能据此重复POST。回归覆盖空页和完整撤销后验证/幂等路径。
- detail同源原生GET，connectApplicationSection目标label.id必须匹配，revokeApp行url=#revokeConnectedApp。named alert id=revokeConnectedApp/preferredButton=removeButton，其唯一destructive=true POST button.id=removeButton、路径/security/apps/<client>/delete。不能用App的email/private/disable/put替代授权撤销。
- iOS15 RUIAlertView原生按钮属性在UIKit action block内。不要点击UIAlertAction或访问block布局：资源回调检查RUILoader._parser与RUIParser.xmlData，NSXMLParser只捕获目标alert唯一button与cancel的4个白名单属性，关联到原生model；不保存整XML、请求令牌或日志body。原生model postbackData保存serverInfo、原生AuthKit signer/RUILoader执行POST。
- Native详情GET真实携带query。保留服务端原生GET/POST会话query，不输出其URL/参数；同源HTTPS、确切bundle/client/path/method、拒绝fragment仍保留。不要移除原生query，也不要把所有含query的链接拒绝（初版曾因此误判）。GET使用ReloadIgnoringLocalCacheData。
- 新列表确认目标不在且身份不变才succeeded；已经不在且列表读成功则already_stopped、不POST。提交后未知响应/目标仍在/新列表失败/身份变均unknown栅栏，不重试。只停止应用授权，不退出设备Apple ID、改全局forward或保证App现有session即时退出。
- 工具apple-siwa.m（stdin action=query/apple_id，或stop/apple_id/bundle_id），300秒外层期限；聚合apple-state亦改300秒覆盖三种profile读取。主机SignInWithAppleTests直接测试native资源捕获、完整列表/空列表/schema、精确target/confirmation/routes/native query、撤销/fresh失败/identity/timeout/幂等/fence；aggregate验证新增分项失败与前后身份变化丢弃三种profile。
- AuthKit AKAppleIDAuthenticationController.revokeAuthorizationForApplicationWithClientID线索经固定GitHub反编译指向AuthorizationStoreManager本地store。不能把本地cache删除当Stop using Apple ID服务端撤销。来源仍EthanArbuckle固定e26ed4563f78871c59d2d96856756a65d62517e5；iOS18线索需iOS15运行时确认。本实现以iOS15实际native Settings表单为准。
