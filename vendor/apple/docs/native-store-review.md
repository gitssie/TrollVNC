# iOS 原生 App Store 首次 Review：已验证流程

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
