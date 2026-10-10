# iCloud 开通限额：设备身份试验

日期：2026-10-07。设备：iPhone 7 Plus / iOS 15.8.8 / Dopamine RootHide。
用户明确要求逐项验证 GitHub 的设备标识替换思路。

## 环境与范围

开始前及每次回调结束后的独立 queryState 均确认：同一目标账号的活动且已认证 App Store、idms 已登录；主 iCloud 不存在，Find My=false。
使用既有原生 TVAppleServices.enableICloud 流程及相同 entitlement，通过临时独立命令行进程执行；认证、Anisette、CDP 仍由 Apple 框架处理。密码和手机密码仅 stdin 输入，未写文件/参数/环境变量。没有新的验证码挑战，没有取码或轮询。

所有替换局限于临时测试进程：未安装持久 tweak，未注入 akd/accountsd，未编辑 MobileGestalt 缓存、硬件序列号或系统账户数据库。每次生成新的测试标识并仅保存在内存。实际机器标识仅在内存用于精确匹配，不输出。
上述设备标识替换是原生对照试验，不代表上游完整部署。后续独立 GSA / loginDelegates 实测另见下节。

## 已执行的试验

| 方案 | 实際生效证据 | 结果 |
| --- | --- | --- |
| 客户端 UUID 替换 | 拦截完整原生登录请求：1个请求改变、2个字段改变，其中1个body字段为client-id；该试验未新增HTTP响应探针 | 原生额外交互失败，主iCloud仍不存在；不能据此判断完整macless-haystack方案失败 |
| 请求层设备字段替换 | 1个完整登录请求改变、共3个字段改变，其中1个body字段；替换存在的客户端/设备ID及序列号请求头。没有证明所有设备身份材料被替换 | 原生HTTP409；alert分类account_limit=true、activation=true；主iCloud仍不存在 |
| 原生 getter 替换 | AADeviceInfo实例/类udid、serialNumber，AKDevice实例uniqueDeviceIdentifier、serialNumber；本次被调用UDID 3次、序列号1次 | 原生HTTP409；同一限额alert；主iCloud仍不存在 |
| MobileGestalt hook | 当前RootHide ElleKit的MSHookFunction，仅本进程hook MGCopyAnswer；匹配SerialNumber / UniqueDeviceID / UniqueDeviceIDData，遵守Copy函数CF对象所有权；本次总命中4次（UDID 3次、serial 1次） | 原生HTTP409；同一限额alert；主iCloud仍不存在 |

初次诊断只hook AARequest基类urlRequest，完整body尚未组装，改变字段计数为0。该次不能计为有效替换试验。修正后遍历实际AppleAccount请求子类自身urlRequest实现，在完整request返回后替换，32个方法入口被覆盖；不得把安装hook数量当实际请求数量。

原生HTTP响应只输出status、error domain/code；alert只输出关键词分类，不输出文字、HTTP body、请求头值或认证结果。原生enable返回unknown时已等待completion结束，再用独立进程查主账户仍不存在后进行下一种明确不同的对照；没有自动重放同一请求。

## 结论及边界

当前证据说明：在这台设备和这个尚未开通iCloud的账号上，仅修改测试进程可见的这些标识未解除开通限额。不能推断Apple只按serial/UDID计数，也不能把macOS虚拟机成功案例当本机成功。

没有替换Apple daemon内的设备身份、硬件证明或NAC/ADI材料；尚未验证完整TLS代理改写或另一台真实Mac首次开通；后续虚拟Mac NAC/V2实测见文末；独立GSA/旧delegate请求已测试，结果见下节。账户依然保持原App Store/idms登录，iCloud未开通，Find My关闭。

## 源码参考

- [ios_ssl_proxy/ProxyRewrite.py](https://github.com/scottgl9/ios_ssl_proxy/blob/master/ProxyRewrite.py)：Apple请求body/header中的设备字段替换，还存在编码字段处理，不能把本次少量明文字段替换当整个代理已验证。
- [macless-haystack/pypush_gsa_icloud.py](https://github.com/dchristl/macless-haystack/blob/main/endpoint/register/pypush_gsa_icloud.py)：独立GSA认证、生成客户端/设备UUID、iosbuddy/loginDelegates；与原生账号开通调用不等价。
- [MGSpoof/Tweak.xm](https://github.com/Tonyk7/MGSpoof/blob/master/Tweak.xm)：选定进程MobileGestalt hook。
- [Apple限额说明](https://support.apple.com/en-us/101661)：另一台iPhone/iPad/Mac先设置iCloud，或使用已经设置过iCloud的账号。

## 独立 GSA 和 iCloud delegate 请求

手机连接可用时，先通过手机原生NSURLSession作为临时网络传输，运行独立Python SRP/GSA认证。Anisette来自仅监听127.0.0.1的临时Docker ADI服务，配置目录为tmpfs；密码/验证码/PET仅进程内存和私密stdin传递，不输出、不写文件。ADIServer不接收AppleID密码。

- 原生AuthKit的AKPassword与GSA专用PET不能不经验证当成同一凭据。原生AKPassword直接用于旧delegate请求曾被密码相关错误拒绝；后续正确获取GSA返回的com.apple.gs.idms.pet token。
- GSA客户端信息中的com.apple.dt.Xcode改为com.apple.akd/1.0后，原先HTTP503变成200/ec=0。参考[Dadoum/anisette-v3-server#59](https://github.com/Dadoum/anisette-v3-server/issues/59)。这不说明所有503都由该字段引起。
- 实测受信任设备验证码提交：POST /auth/verify/trusteddevice/securitycode，JSON为securityCode.code，HTTP204；此前旧GET验证路径未成功。验证码由外部单独curl获得，登录代码不取码、不轮询。之后GSA完成认证。
- 使用真实GSA PET的iosbuddy/loginDelegates返回外层status=0，com.apple.mobileme.status=1，消息分类limit，无mobileme tokens。不能只按外层status判断成功，也不能认为GSA成功即iCloud开通。

### 手机断开后的纯独立客户端（2026-10-07）

手机USB已拔出，后续请求由Python requests直接发送，TLS校验开启、重定向关闭、有限超时；不依赖手机SSH或网络传输。用户明确要求保护开发Mac：只检查AAAbsintheContext类和方法签名，未实例化验证上下文、未生成开发Mac NAC、未读取其账户凭据、未将其硬件身份交给目标账号，也未修改Mac AppleID/iCloud/钥匙串/系统配置。

1. 初版随机元数据与ADI不配套：GSA init 200/ec=0，complete 200/ec=-22406；不得直接认定密码错误。
2. 改用独立ADI服务返回的配套MD/MD-M/RINFO/MD-LU/DeviceID等元数据：GSA s2k init和complete均200/ec=0，无新验证码挑战；同一目标账号旧delegate依然status=0/mobileme.status=1/limit，无tokens。多项字段同时改变，尚未隔离究竟哪一项导致初版拒绝。
3. 按rustpush结构构造/setup/signin/v2/login：protocolVersion=1.0、userInfo和mobileme delegate、Basic认证使用GSA PET；有意不构造假NAS、不使用开发Mac身份。返回HTTP400且非plist，无token可验证。本次缺少上游要求的X-Mme-Nas-Qualify，其他请求细节也未完成全量对照；不能将HTTP400的确切原因认定为NAC，不能当成带有效Mac证明的完整方案已经失败。

[rustpush auth.rs](https://github.com/OpenBubbles/rustpush/blob/master/src/auth.rs)显式调用generate_validation_data并携带X-Mme-Nas-Qualify；[macos.rs](https://github.com/OpenBubbles/rustpush/blob/master/src/macos.rs)展示证书、session-info-request、key establishment、sign流程。其公开[OpenAbsinthe-Stub](https://github.com/OpenBubbles/OpenAbsinthe-Stub/blob/main/src/nac.rs)核心方法为todo，不能只clone后称已具备证明生成能力。发现的原生[AAAbsintheContext参考实现](https://github.com/mosessupposeshis/imessage/blob/master/nac-validation/src/validation_data.m)已读代码并编译，但未在开发Mac运行生成数据。

后续已经生成完全虚拟Mac的NAC并测试V2流程，见下节。当前未完成iCloud开通；手机离线后也未重新查询其状态，不把网络侧认证成功当作本机登录成功。临时独立客户端位于/tmp，未纳入生产模块。设备诊断文件尚未全部清理，因手机离线无法清理；没有持久hook进程。


### 完全虚拟 Mac NAC 与条款请求

用户进一步授权生成虚拟设备数据。开发Mac只查询IOKit属性是否存在、类型及长度，未复制其serial、MLB、ROM、UUID值；AAAbsintheContext只做类/selector检查，未在宿主机生成NAC。独立Linux/amd64容器内运行x86 Unicorn模拟器，所有硬件查询由合成配置回答。

- 完整实现来源：[imessage/open-absinthe/nac.rs](https://github.com/mosessupposeshis/imessage/blob/be8d3f83be30a88dca26ee7ad1fb862b8af889e9/rustpush/open-absinthe/src/nac.rs)，不是OpenAbsinthe-Stub。临时工作副本只启用Unicorn x86，移除宿主机native-nac依赖。
- 虚拟配置使用MacBookPro15,1及其board-id，serial/MLB由[OpenCore macserial](https://github.com/acidanthera/OpenCorePkg/tree/master/Utilities/macserial)的指定型号生成模式产生，UUID/本地管理MAC/ROM另行生成；未运行读取本机硬件的模式。合成配置不是开发Mac硬件快照。
- 模拟器执行限制必须校验RIP已到STOP_ADDR。初版100M指令上限提前终止，RAX=1300678094不是有效NAC错误码；修正为35秒执行期限并检查函数正常返回后成功。加密字段known-vectors测试1项通过。
- 实测init生成338字节request、Apple session握手HTTP200、最终sign生成517字节proof。请求及proof只在私密进程管道传递。握手成功不等于账号开通或所有后续服务已接受设备资格。
- 携带虚拟NAC的/setup/signin/v2/login返回HTTP409，ErrorID/localizedError=MOBILEME_TERMS_OF_SERVICE_UPDATE，尚无mobileme token。这与此前旧delegate的limit分类不同，但不足以证明开通限额已解除。
- /setup/update_account_ui返回HTTP200 HTML。页面资源必须相对其base=/resource/cee1d7fc0119/加载，不能直接按/setup/js/构造。账户HTML、认证头、cookie仅内存，不保存。
- 按实际页面core.js选择basic_auth_update_account或token_auth_update_account，使用服务端authHeader、版本字段、fresh NAC及form编码。实测HTTP200但success=false、dsError=false、error=Error creating account.，无accepted-terms头或termsAccepted cookie。HTTP200不代表条款/开通成功。
- 修正为服务端authHeader、每次fresh NAC、统一虚拟client-id后结果相同。按[rustpush UpdateAccountFinish::MacOS](https://github.com/OpenBubbles/rustpush/blob/master/src/auth.rs)携带termsAccepted=true重试V2，也仍HTTP409/terms，无token。不得把自行携带的cookie当服务端已确认接受条款。
- GSA请求改为独立短会话及Connection: close后两次认证成功；此前一次ec=-22406的原因仍未隔离，不能宣称连接复用就是其根因。

上述代码仍是/tmp研究客户端，未接入vendor/apple生产开通路径，也未登录开发Mac系统账户。密码只getpass私密stdin，ADI服务不接收密码，验证码仍由外部单独获取和提交。手机离线，网络侧测试不代表手机主iCloud/CDP配置已完成。


### 最终成功：原生 BuddyML 条款接口 → 虚拟 Mac V2

同一目标账号、同一隔离ADI/虚拟Mac配置，采用[rustpush UpdateAccountFinish::IOS](https://github.com/OpenBubbles/rustpush/blob/master/src/auth.rs)实际实现的原生条款路线。客户端是Python HTTP测试程序，没有打开浏览器，没有登录开发Mac系统账户：

1. POST /setup/iosbuddy/ui/genericTermsUI，plist为format=plist/buddyml、terms=[{name:iCloud}]；认证沿用GSA PET、ADI及账号上下文，携带fresh虚拟NAC。HTTP200返回BuddyML XML。
2. 从XML clientInfo读取唯一agreeUrl，仅允许https://setup.icloud.com/setup/下服务端提供的地址；不硬编码或记录其会话参数。POST该地址、Content-Type=application/xml、空body，生成fresh NAC。返回HTTP200/空body，并存在X-Apple-I-Accepted-Terms头。这个结果区别于前述失败的网页form或自行设置cookie。
3. 再以fresh虚拟NAC调用/setup/signin/v2/login：HTTP200、外层status=0、com.apple.mobileme.status=0，service-data.tokens为dict。网络侧iCloud初始化/登录凭据获取成功。
4. 去掉NAS，用同一有效GSA PET独立调用旧/setup/iosbuddy/loginDelegates：HTTP200、外层status=0、mobileme.status=0，没有此前limit消息。该诊断的has_mobileme_tokens只检查delegate顶层tokens，输出false；未检查service-data.tokens，因此不能据此声称旧接口没有token。开通凭据证据以步骤3的实际service-data.tokens为准。

所有认证结果、token、cookie、XML只留在测试进程内存，执行结束后不保存。本轮未触发额外验证码。手机仍离线，没有向手机写入主iCloud账户，也未执行其CoreCDP或本机密码验证；结论限于账号在网络侧的首次初始化成功，不代表手机已经登录。此前各节的“未开通”是当时试验结果，已由本节网络侧成功结果更新。

成功的临时入口：/tmp/cazer-run-direct-virtual-mac-native-terms.py，原生条款适配/tmp/cazer-tos-native-extension.py，虚拟NAC客户端/tmp/cazer_virtual_nac_client.py，模拟器工作树/tmp/cazer-nac-virtual-work/open-absinthe。它们尚未纳入生产模块，后续需整理许可、固定上游版本、失败/超时/敏感输出边界和独立依赖，不能直接让生产模块任意执行研究脚本。
