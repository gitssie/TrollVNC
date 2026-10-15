# Apple 操作与 HTTP/2 状态流设计

状态：接口设计，尚未接入 HTTP 路由或 RV。当前生产接口仍为 invoke/result/submit_code。

## 问题与边界

一次 Apple 操作可能经过认证、验证码、本机密码、CDP 和保存账户等阶段。输入 provider 的明确拒绝、总 completion、超时和迟到回调必须交给同一个操作状态管理器。HTTP/2 提供并发响应流和流控，不提供业务回调排序、请求去重或副作用回滚。这些保证由手机端操作管理器实现。

已复现的旧路径：输入 provider 已记录错误，但 iCloud 等待循环仅观察总 completion，直到 240 秒兜底才读取输入错误。此次修复让输入错误与总 completion 竞争同一终态门；明确拒绝立即结束，迟到 completion 不改写结果。它不是下述完整流协议的实现。

## 三种接口形状

方案一是单个长响应：`POST /api/apple/operations:run` 直接返回 NDJSON，RV 读取直到终态；验证码另发 `POST /api/apple/operations/{id}/input`。服务器隐藏原生回调与轮询。常规调用最简单，但首个响应丢失时仍需请求标识找回操作；断流恢复又需要 attach 接口，因此“一条请求”无法覆盖恢复语义。

方案二是事件日志：`POST /api/apple/operations` 创建操作，`GET /api/apple/operations/{id}/events?after_seq=17` 重放后续事件，输入另发 POST。RV 保存游标并重放 reducer；手机端隐藏原生线程与日志。它适合完整审计，但必须处理日志保留、游标失效、重放兼容和敏感信息，UI 所需的复杂度较高。

方案三是操作状态快照：创建后订阅 `GET /api/apple/operations/{id}/watch?after_revision=17`，每次收到完整状态，直接替换较旧版本；`GET /api/apple/operations/{id}` 随时读取同一份状态。手机端隐藏回调竞争、阶段切换、输入去重与断线恢复。慢客户端可以跳过中间进度而仍然拿到最新状态，适合 RV。

采用方案三，并吸收方案二的单调版本与请求去重。UI 不依赖完整历史；未来审计可以另加经过脱敏的日志，不让日志成为执行前置条件。

## 推荐接口

所有接口复用现有 Bearer 授权。权限失效立即结束订阅，重新授权后可以读取允许访问的操作；操作 ID 本身不是授权凭据。

| 接口 | 语义 |
| --- | --- |
| `POST /api/apple/operations` | 提交 `{request_id, method, params}`，返回 202 和当前快照 |
| `GET /api/apple/operations/by-request/{request_id}` | 创建响应丢失时找回操作，不执行写入 |
| `GET /api/apple/operations/{id}` | 读取当前完整快照 |
| `GET /api/apple/operations/{id}/watch?after_revision=N` | NDJSON 快照流，终态发送后关闭 |
| `POST /api/apple/operations/{id}/input` | 提交 `{input_id, stage_id, challenge_id, value}`；返回接受凭据及当前快照 |

RV 一次业务调用为 `run(method, params)`；内部负责创建、订阅和输入。不把 HTTP/2 stream ID 当 operation_id，重连后的 stream ID 可以变化。

创建的 request_id 由 RV 在发请求前生成。同一授权范围、同一 daemon epoch 内，同 ID、同参数只返回原 operation_id；同 ID、不同参数返回 409。注册去重项、分配操作和占用执行会话在提交原生调用前原子完成。参数仅在必要的内存生命周期内保留；匹配摘要使用进程密钥 HMAC，不保存密码或低熵验证码的裸摘要。显式重新操作使用新 request_id。

请求去重记录与结果当前采用 600 秒保留、64 个操作容量，创建前做容量判断，不驱逐未到期结果。同一请求的过期去重标识作为有界 tombstone 保留至本次 daemon epoch 结束；tombstone 容量耗尽拒绝新建，不淘汰后重新执行旧 ID。过期查询返回 410。客户端不会因超出保留窗口自动再次创建。

## 状态结构

```json
{
  "epoch": "daemon-instance-uuid",
  "operation_id": "operation-uuid",
  "revision": 4,
  "method": "enableICloud",
  "status": "completed",
  "stage": "icloud_cdp",
  "stage_id": "stage-generation-uuid",
  "terminal": true,
  "outcome": "failed",
  "effect_state": "possibly_partial",
  "error": {
    "domain": "org.trollvnc.apple",
    "code": 11,
    "message": "Native iCloud/CDP sign-in failed.",
    "native_domain": "com.apple.appleaccount",
    "native_code": 403
  }
}
```

`status` 为 running、waiting_input 或 completed；`outcome` 仅终态携带 succeeded、failed 或 unknown。`effect_state` 为 not_submitted、confirmed 或 possibly_partial，它描述账户副作用，与执行结果独立。原生明确拒绝为 failed，即便此前可能保存过部分账户；没有终态证据的截止超时为 unknown。失败后 fresh 查询不成功，不覆盖原始明确错误；查询成功也不冒充 CDP 总流程完成。

等待输入的快照包含 challenge 和手机端决定的到期信息；最终快照移除 challenge。密码、验证码、token、cookie、原生 userInfo 和原生任意 description 不进入快照、日志或去重存储。仅允许模块自有文案与白名单原生 domain/code。

## 唯一状态所有者

每个操作有独立串行 reducer；原生回调只提交带 `{epoch, operation_id, stage_id}` 的消息，不直接写 UI 或缓存。所有终态、挑战、超时和输入接受都经过该 reducer。

```text
created → running ↔ waiting_input → completed
             └── 明确失败/截止超时 ──┘
completed 没有出边
```

- `publish(token, state)`：仅当前阶段、尚未结束时更新快照，revision 加一。
- `continue(token, next)`：仅当前阶段、尚未结束时安排下一步原生工作。每个阶段只消费一次继续权限；实际异步入口再次检查 token，防止排队期间阶段失效。
- `finish(token, result)`：第一次合法终态获胜，取消计时器、关闭输入并释放此操作的执行会话；后续 finish 不改变结果。

每次进入新阶段更新 stage_id；相同阶段收到重复成功也不能启动两次后续写入。超时与成功在同一 reducer 上决定先后。关闭本地 gate 不声称已经取消 Apple 后台写入，已提交副作用可能随后显现。迟到回调仅清理资源；可触发独立只读查询刷新账户视图，不修改原操作终态。

不恢复跨功能 unknown 栅栏。仅仍被真实原生调用占用的同一会话返回 busy；管理器已经判定结束而原生库仍持有专属资源时，资源占用独立跟踪并有自己的清理期限，不阻止其它功能，不把旧操作继续显示为处理中。

## 输入、超时和断线

输入使用 stage_id + challenge_id 校验当前挑战，input_id 去重。同一 input_id 重试返回原接受结果，不重复喂给原生库；相同 ID 内容不同或挑战已失效返回 409。接受输入时先原子消费挑战、保存收据并增加版本，再安排原生 continuation，避免同步回调被旧 running 状态覆盖。不同 input_id 不得重复消费同一挑战。

各阶段设置独立 deadline，例如等待用户验证码使用挑战有效期，原生执行使用该步骤的上限。明确错误立即 finish，不继续消耗 deadline。连接空闲计时、阶段执行计时和用户输入计时分别维护；心跳只证明订阅连接存活，不延长业务 deadline。各原生步骤的具体上限应按已有实现及真机测量确定，不能用一个 240 秒覆盖全部阶段。

watch 建立时，注册订阅与读取快照必须原子完成：版本比 after_revision 新则立即发送当前快照；终态无论游标是否相等都发送一次并关闭。游标超前返回 409，epoch 不同返回 operation_unavailable。以 NDJSON 行分隔完整消息，客户端不能将 HTTP/2 DATA frame 当消息边界。

每个订阅最多保留一份待发送最新快照；慢客户端合并中间版本，终态保留在权威操作记录。网络发送不持有 reducer 锁、不阻塞原生回调。底层发送接口应明确区分 sent、backpressured、closed；当前 bool try_send 不足以区分满队列与断流。背压过久关闭订阅，RV 重连后从快照恢复。订阅数、单行大小、总缓冲和心跳频率均有限制。

HTTP/2 EOF、RST_STREAM、连接断开和 JWT 到期只结束订阅，不撤回已提交 Apple 写入。RV 重新授权并 GET/watch，绝不重放 mutation。用户关闭面板是 detach；若以后提供 cancel，必须单独定义能力、取消请求与取消已确认，不能把关闭响应流当成成功撤销账户修改。

daemon 重启会变更 epoch；本设计不持久化凭据或执行日志，无法承诺跨重启找回原生执行结果。RV 对丢失的已提交操作显示结果未知，独立查账户状态；不得在新 epoch 自动重发。

## RV 行为与迁移验证

RV 以 operation_id + epoch 关联当前表单，只应用更大的 revision；输入 POST 的旧响应不能覆盖 watch 已到达的新终态。completed 时原子清 busy、挑战、当前操作引用与自动取码任务，结果另外保留用于展示。再次点击功能创建新操作，关闭面板不让历史结果重新成为可提交表单。

先将当前 Apple adapter 状态更新集中进上述 reducer，仍支持旧 result 读取；再增加 watch/输入路由与能力声明，RV 按能力选择新客户端。两条读取路径访问同一权威快照，不能各维护一份状态。新协议未上线前，不在 capabilities 宣称支持。

必要验收：明确失败且总 completion 缺席；先失败后成功；先成功后失败；阶段重复回调；旧阶段挑战迟到；输入与终态竞争；旧输入响应后到；并发重复 request_id/input_id；创建收据丢失后找回；断流后终态找回且写入计数为一；慢订阅与背压；过期/tombstone/容量；JWT 过期；daemon 重启；最终状态不可复活。HTTP/2 用真实 peer 验证分片、流复用和断开，原生 reducer 用可控回调验证顺序，不用测试专用的复制状态机代替生产代码。

参考：[RFC 9113 HTTP/2](https://www.rfc-editor.org/rfc/rfc9113.html)，尤其 Streams and Multiplexing、Flow Control、RST_STREAM 和 Request Reliability。上述 operation、revision 与业务去重是应用协议设计，不是 HTTP/2 自动提供的保证。
