# iOS 原生 App Store 首次 Review：已验证流程

## GSA PET → 真机 Review 衔接成功（2026-10-11）

在 iPhone10,3 / iOS16.7.10 / 20H350 真机完成了跨凭据来源实验。
目标是此前纯 HTTP Review 最终返回 FraudScoringTxn 的同一未转换账号。
GSA 使用既有 Intel profile / 持久 ADI / 12334 代理取得新的 PET；只有
账号名和 PET 经 SSH private stdin 交给真机，没有传入账号密码、Intel
设备请求头、Cookie 或模拟 SAP 上下文。手机没有重新调用 AuthKit 密码认证。

实测顺序和结果：

1. GSA init/complete 均 HTTP200/ec0，无验证码挑战。
2. `TVAppleNativeStoreLoginForReviewWithPET` 返回 needs Review / code10；
   `TVAppleNativeStoreReviewAuthentication` 成功，保留原生 response/context。
3. 手机复用 `TVAppleNativeStoreSignIn` 的现有账单获取方法，自行取得美国六字段地址。
4. 现有 `TVAppleNativeStoreReviewSession` 完成原生设备信息、SAP priming/proof
   和签名，None/同意条款的账单校验 HTTP200/status0。
5. 只提交一次最终转换，HTTP200/status0，完整 result/details 成功。
6. 后续独立原生 Store 登录 attempt0，`review_required=0`。探针 exit0/stderr0。

因此已证明本次 GSA PET 可以交给真机完成 Review；不是只能使用手机 AuthKit
产生的 PET。它不证明纯 HTTP 路径已修好，也不能把差异归因于某个请求头：
真机设备身份、ADI、Cookie、SAP、原生请求准备和网络路径仍是整体差异。
本次没有开通 iCloud，也不以 Store 认证结果声称活动媒体账户已持久化保存。

`tests/apple-store-review.m` 现在支持外部 PET 模式：private stdin 首行为
`apple_id`、`pet`、`auto_address:true`、`complete_review:true`。
不要同时传 password；空/非法 PET 或两种凭据并存直接拒绝。该模式不会退回
手机密码认证。`complete_review:false` 可仅校验，`billing` 可继续手动传入。
这里只扩展设备探针，未增加公开 Services、ZXTouch 或 AppleServices HTTP 接口。
凭据只在管道和短期原生会话中传递；日志仅记录阶段、状态和模块诊断。

构建仍用既有 `build_device_probe.sh ... apple-store-review.m`，本次 arm64/ARC/
`-Wall -Wextra -Werror` 构建通过。设备临时探针已删除；不要再次为这个已转换
账号重放最终 Review POST。

2026-10-10，在 Dopamine / RootHide、arm64、iOS 15.8.8 真机完成：原生认证 → 首次 Review → 同意条款 → 美国账单地址 → 支付方式 `None` → 保存 → 再次 Store 登录不再要求 Review。

## 成功证据与范围

- 原生 AuthKit 认证成功，取得本次认证返回的 `AKPassword`。
- 首次探针的 Store 初次认证返回 type 3 / Review，预转换认证返回 type 4；后续 ZXTouch 新账号预转换仍返回 type 3 / 有效 Review continuation，也已完整转换成功。
- 账单校验：HTTP 200，JSON `status=0`，`validationResults=[]`，返回新的 `pageUUID`。
- 最终转换：HTTP 200，JSON `status=0`，`result` 含账号信息、`details` 和 Store cookies，没有额外验证分支。
- 独立后续 Store 登录：认证成功，`review_required=0`。

首次转换成功使用设备探针第 30 版；后续正常登录使用第 32 版。整理后的代码增加了失败、超时、异常类型和重复提交的主机回归；随后另一未转换账号已通过 ZXTouch 完整转换，见文末。成功时使用独立 Apple 模块的 private 接口与真机测试入口。后续已接入现有 TrollVNC ZXTouch 登录分支（见文末），尚未安装新的正式包；不新增 HTTP 动作。以上结果不代表 iCloud 已在本机开通。

## 原生调用顺序

1. 使用本机 AuthKit 认证。验证码由外部提交给 `TVAppleManualCodeProvider`，模块不读取短信 URL、不联网取码。短信续传接受 Apple 实际返回的成功 2xx；保留原生发送、验证和签名流程。
2. 将本次 AuthKit 的 `AKPassword` 作为原生 Store 凭据调用 `TVAppleNativeStoreLoginForReviewWithPET`。`initialPassword` / PET 槽不能填普通账号密码。
3. 从实际 Store 响应取得 `convertWizard` 入口，保留服务器完整 query。需要 Review 时，再调用 `TVAppleNativeStoreReviewAuthentication`，通过原生 `shouldIgnoreAccountConversion=YES` 建立预转换 Store 会话；这一步本身不代表 Review 完成。必须同时输出 response/context。type4 可建立预转换会话；type3 仅在原生 code10、有效 context 和合法 Review 路由齐全时续接，使用这次新的服务器响应。所有 Review 认证均抑制原生对话框。
4. 创建 `TVAppleNativeStoreReviewSession`，调用 `validateBilling:error:`。设备 GUID、序列号由 `SUScriptInterface` 提供，用户代理由 AMS 原生编译；不生成 profile、不伪造设备头。
5. SAP 使用 `SUSetupMescalSessionOperation`，交给 `ISOperationQueue` 执行。原生 Mescal 会话以空数据生成 account-creation priming signature，作为 `X-Apple-ActionSignature` 请求实际 Review 入口；由原生 `verifyPrimeSignature:error:` 接受服务器证明，再从服务器 HTML 跳转取 `pageUUID`。不创建或展示 `SUAccountViewController`。
6. 账单模型来自原生 Bag 的 `convertAccountFieldsSrv`，保留服务器账号姓名及默认数据。校验只提交账单相关字段、条款、页面令牌、设备信息和签名。
7. 校验成功后调用 `submitConversion:error:`。最终 Bag key 是 `createAccountSrv`，转换上下文是 `convert`。只发送一次最终提交；失败或超时不会自动重放。

Store / AuthKit 基础登录沿用 [appknox/appstorectl 的固定版本](https://github.com/appknox/appstorectl/tree/4b60f16b2066056cc9a9c53da9a61c1aa53fec2f)，本模块保留其 MIT 通知。Review 原生 priming 调用参考 [SUAccountViewController](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/main/System/Library/PrivateFrameworks/iTunesStoreUI.framework/SUAccountViewController.m)、[SUSetupMescalSessionOperation](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/main/System/Library/PrivateFrameworks/iTunesStoreUI.framework/SUSetupMescalSessionOperation.m) 与 [SUWebViewController](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/main/System/Library/PrivateFrameworks/iTunesStoreUI.framework/SUWebViewController.m)。这些反编译资料对应 iOS 18；本模块实际 selector、回调参数和上述成功结果来自 iOS 15.8.8 真机，不能直接推论其他系统兼容。

## 请求参数与签名

| 项目 | 使用方式 |
| --- | --- |
| 国家 | `iso3CountryCode=USA`、`addressOfficialCountryCode=USA` |
| 支付方式 | `paymentMethodType=None`，大小写保持官方选项值；本次服务器允许 None |
| 条款 | `agreedToTerms=1`，仅在用户授权同意后提交 |
| 街道 / 城市 | `addressOfficialLineFirst` / `addressOfficialCity` |
| 州 / 邮编 | `addressOfficialStateProvince`，如 `CA`；`addressOfficialPostalCode` |
| 电话 | `phoneOfficeAreaCode` 与 `phoneOfficeNumber` 分开提交 |
| 姓名 | 保留服务器已有姓名；缺少账单姓名时使用已有账号姓名，不生成随机身份 |
| 校验签名内容 | UTF-8 的 `pageUUID + machineGUID` |
| 最终签名内容 | UTF-8 的 `pageUUID + machineGUID + acAccountName` |
| 签名字段 | 原生签名 NSData 的 Base64 → `xAppleActionSignature` |
| 转换路由 | Bag 解析出的真实 endpoint，URL query 带 `context=convert` |
| POST 正文 | 标准 URL-encoded form；签名中的 `+` 必须编码为 `%2B` |

参数布局、Bag key、签名串和选项值依据 [Apple Finance 官方 JavaScript](https://finance-app.itunes.apple.com/assets/finance-app-28b084fc4a5d29261c2354e899c99572.js) 中的 `account/create-convert-route`、`account/convert-account`、`services/fair-play` 和 `utils/payment-methods`。原生签名字符串编码与 Base64 返回行为见 [SUScriptFairPlayContext](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/main/System/Library/PrivateFrameworks/iTunesStoreUI.framework/SUScriptFairPlayContext.m)。

不能仅凭 HTTP 200、预转换认证成功或字段模型读取成功报告已完成。账单校验必须没有服务器字段错误；最终转换必须取得完整、无矛盾的原生成功响应。

## 运行权限和数据生命周期

真机测试签名在 `tests/entitlements.plist`。除了已有的账户 / AuthKit / itunesstored 权限，本次使用实际 App Store 二进制中的 `fairplay-client` 声明建立原生 FairPlay 会话；该声明已通过本机实际握手和签名验证。其他运行入口须检查实际有效权限，不能只看到 plist 就宣布可用。

密码、AuthKit 结果、Store 上下文、SAP 会话、页面令牌、原始响应及 cookies 只保留在本次进程内。接口返回的原始响应属于私有认证材料，不打印或写入知识文档。超时关闭认证 ticket、清除上下文凭据，晚到回调不重新开放会话；SAP 仅在服务器 priming proof 被原生接受后缓存。

美国账单地址由既有 `AppleServices/scripts/us-billing-address.py` 获取，然后经 private stdin 提供给真机探针。该外部工具不成为 Apple 原生认证模块的联网或取码依赖。

## 代码入口与复用

- `private/TVAppleStoreLogin.h`：Review 认证与原生认证结果的衔接。
- `private/TVAppleStoreReview.h`：短期转换会话；`validateBilling` → `submitConversion`。
- `src/appstore/TVAppleStoreReview.m`：原生设备信息、Bag、SAP、校验与最终提交。
- `tests/apple-store-review.m`：静默真机入口，私密 stdin；仅输出阶段、HTTP / Finance 状态和模块错误。
- `tests/StoreReviewTests.m`：None、已有姓名、校验拒绝、异常模型、提交超时及不可重复提交。
- `tests/StoreReviewAuthenticationTests.m`：密码 / PET 槽分离、抑制对话框、预转换上下文及关闭后的晚到结果。

从 TrollVNC 目录运行：

```bash
rtk proxy bash vendor/apple/tests/run_tests.sh
rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-store-review apple-store-review.m
```

探针的首行 JSON 包含 `apple_id`、`password`、`auth_first=true`、`complete_review=true` 和 `billing`。`billing` 使用上表六项地址 / 电话字段。若产生挑战，下一行提交 `challenge_id` 与 `code`。不要把真实密码、验证码或取码 URL 写进 shell 参数、环境变量或文件。已完成转换的账号再登录会直接返回 Store 成功，不再次设置账单地址。

## ZXTouch 登录分支接入（2026-10-10）

生产登录现通过 `TVAppleNativeStoreSignIn` 完整编排，`signInAppStore` 的账号/密码协议不变。Review 时由 iOS NSURLSession 自行请求现有美国账单工具，忽略非账单字段；无需主机 Python 或客户端 billing 参数。普通账户不取地址。调用方需按原有接口提交验证码。同一操作中完成原生认证、转换和后续 Store 登录；后续登录未知不覆盖已确认的转换成功，也不重放。参见 [ZXTouch 调用文档](../../../docs/apple-zxtouch.md)。私有探针 `apple-store-billing.m` 可只验证手机获取地址，不修改账户。

### ZXTouch 新账号完整真机验收

2026-10-10：按用户要求，先通过 task31 signOutAppStore 退出原媒体账号，再从项目 tempdir/apple_account.txt 选择另一个未开通测试账号。SMS 挑战由外部获取新码并通过 submit_code 续接；iOS 自行取美国六字段地址。完整 signInAppStore operation 返回 outcome=succeeded、authenticated=true、review_completed=true、payment_method=None、billing_address。独立 queryAccountState 确认新媒体账户 selected/authenticated=true，原 iCloud 账户保留、Find My=false。

正确流程支持预转换 type3/合法 Review/context continuation，而不是强制必须 type4；严格限定此原生分支，仍由校验和最终转换响应决定完成。Services 的登录切换冲突检查只覆盖 selected media，允许 App Store 与 iCloud/identity 不同账号。测试经源码构建的独立 ZXTouch socket 服务，复用正式适配器/Services/后端与daemon entitlements；未替换运行中的正式 TrollVNC 包。没有打开 UI，没有持久化凭据或原始认证响应。

## 2026-10-11：同账号同账单真机最终提交成功

在上一轮 Intel 最终拒绝之后，用户明确要求将同样信息通过真机提交对照。账号文件第18行 lavonrathxpa，继续原 Intel 设备/ADI fresh GSA PET，只向 iPhone 传 apple_id/PET 和同一账单六字段，不做 native password fallback，不复制 Intel Cookie/header/SAP。地址复用上一轮工具获取的 1063 Arrowood Drive / Jacksonville / FL / 32202，电话 904/4575274，支付 None、agreedToTerms=1。

真机 Review 预认证成功；p28 fields HTTP200/status0；入口 proof 验证；validateAccountFieldsSrv HTTP200/status0/pageUUID；一次 createAccountSrv HTTP200/status0/result.details完整。随后原生 Store attempt0/review_required0/error0。probe exit0/stderr0。该账号已转换，禁止重复最终 Review。这里未执行 iCloud 激活，也未验证媒体 selected 状态。

最终接口实际 URL 两边一致：p28-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/createAccountSrv?context=convert。原生 POST 参数在模块提交前完整留存；Intel 上轮未捕获 body，因此根据原字段响应、地址、profile和代码重建（不冒充 wire capture）。比较结果：业务字段、支付、条款、账户名全部相同，无额外/缺失普通字段，lastModified 随 fresh 字段请求更新。设备 guid/machineGUID、serialNumber、pageUUID、xAppleActionSignature 使用各自原生/Intel上下文，不能当普通可互换字段。原生 guid40位（iPhone），Intel guid为MAC对应标识；序列号分别为真机和Intel profile。两边都本地验过服务器 SAP proof；这不证明服务端在最终转换认可两边的全部设备/认证上下文。

因此同一账号和这组账单可完成转换，最终错误不能直接归为账号无法开通或地址不合法。已排除不同最终URL和明显缺失业务表单字段；尚未确认导致 Intel 最终拒绝的具体设备属性、认证/Cookie/header、SAP绑定或网络因素。原生当前账号Cookie是响应后的快照，不是精确出站 header；不能把快照与Intel出站header差异直接当因果证据。Native手机的网络路线与Intel代理并非已控制的相同变量。

新增测试专用 private_native_review_submission_parameters，显式 trace_private_data 时记录 POST 前参数，trace_scope=module_parameters_before_native_transport。生产模块/协议未修改。私密记录：/tmp/cazer-native-review-same-billing-final-20261011/row18-record1–8.json，其中7是最终参数、8是最终成功响应。/tmp/cazer-review-final-parameter-comparison-20261011.json 保留 native参数和明确标注来源的Intel重建。重要引用：TrollVNC/vendor/apple/src/appstore/TVAppleStoreReview.m 的 validateBilling/signatureForAccount/submitConversion，以及 iOS18.2 pinned dump SSVLoadURLOperation._newURLRequestWithRedirectURL 的原生账户/设备上下文准备。不能把这轮原生成功记录为纯 Intel HTTP Review 已完成。

## 2026-10-11：真机仅完成 Review，不登录活动 App Store

用户在Mac真实手机GUID最终被风控拒绝后，要求直接真机完成Review并不保留App Store登录。测试账号文件第23行arikuhicmyjl。SSH mobile@10.17.12.17:2222；执行前SSAccountStore独立只读确认activeAccount为空。为符合要求，在/tmp复制模块构建独立Review-only探针：SSAuthenticationContext.canSetActiveAccount=NO，完成转换后跳过原探针的post-review Store登录检查。未改生产模块或daemon，未调用退出/删除已有账号。补丁tests/review-only-process.patch只能用于这一独立复制模块，不能直接作为生产默认登录逻辑；只读状态探针tests/review-media-state.m。

这轮使用手机原生AuthKit密码/SMS认证，未使用Intel GSA PET，凭据只private stdin。Native Store Review必要预认证保留context，但禁止设置活动媒体账号。原生设备/SAP/proof和fields成功；账单复用Mac上一轮已校验的4505 Gregory Lane/Louisville/KY/40223、电话502/2084743，支付None/同意条款。原生validate实际Bag路径p30/account/v2/create/validateFields，HTTP200/status0；一次最终p30/WebObjects/MZFinance.woa/wa/createAccountSrv?context=convert返回HTTP200/status0、完整details，review_complete=1。随后没有执行Store登录检查。独立SSAccountStore查询activeAccount仍为空；前后媒体状态相同。探针exit0/stderr0。账号已完成转换，不再次提交最终Review。

普通结果docs/review-only-result-20261011.json；主机私密记录/tmp/cazer-native-review-only-result-20261011/result.json和events.txt，无原始认证响应/PET/cookies。手机临时两探针清理。与前一轮Mac比较属于不同凭据来源/原生认证及网络上下文的整体对照，不能将结果唯一归因GUID、SAP或GSA。此次真实手机执行不同于只把手机GUID填进Mac SAP。

重现构建：cp -rf vendor/apple到新的独立/tmp目录，在副本用git apply应用review-only-process.patch，再运行副本tests/build_device_probe.sh输出独立arm64探针。操作前/后用单独read-only media-state探针确认activeAccount状态；成功标志为最终status0且完整details。账号已转换时不要重复最终POST。
