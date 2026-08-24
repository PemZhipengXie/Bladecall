# TICKETS

> 2026-08-24 清仓归档：本仓库暂停在原会话流里迭代，以下是尚未落地的待办与已调研结论。
> 每张票：意图 / 怎么算做好了 / 非目标 / 约束 / 依赖。标注「待拍板」的是推荐方案，尚未经维护者确认。
> 移动端（iPhone App / Widget）工作在私有仓库 Bladecall-iOS，交接文档见该仓库 `docs/`。

---

## T-01 收件箱只显示主对话：子 Agent 会话降噪

### 意图

Mac 浮窗「幕后剑令」组展开后被子 Agent 会话刷屏（本机实测：Codex 主对话 10 / 子 Agent 49 / 后台 exec 33；Claude Code 主对话 18 / 子 Agent 35 / 后台 40，子 Agent 是主对话的 2–5 倍）。维护者判断：没人会去看子 Agent 的复命内容，收件箱应只呈现主对话的注意力事项。

调研已确认**识别是对的，问题在注意力层**——`.subagent` 分类正常工作（`CodexAdapter.sessionOrigin()` 依据 `sourceIsSubagent` / `thread_source == "subagent"` / `parent_thread_id` / `agent_path`；标题「昵称 · 项目」即子 Agent 格式）。噪音的真正来源有四处：

1. 「幕后剑令」组表头的「N 枚待看」计数；
2. 菜单栏角标 `unreadCount` 直接数 `attentionStates`、不看 origin（`Sources/CompletionBell/AppState.swift:274`）；
3. 系统通知开启时，子 Agent 复命同样发通知（`route(event)` 无 origin 门槛，`AppState.swift:697`）；
4. 手机快照同步包含 subagent（iOS 端默认隐藏幕后，影响较小）。

注意：截图中「Codex 后台 · …」类条目是 `.externalRuntime`（`codex exec` 独立任务），**不是**子 Agent，有自己的主任务身份。

### 待拍板（六问，附推荐）

| # | 问题 | 推荐 |
|---|------|------|
| Q1 | 剔除范围 | 只剔 `.subagent`；`externalRuntime` / `detached` 留在幕后组 |
| Q2 | 隐藏程度 | 彻底不入收件箱：不建 attention state、不计角标、不发通知、不进手机快照；`activity.jsonl` 照常记录 |
| Q3 | 跨工具 | 按 `origin == .subagent` 统一处理，不分工具 |
| Q4 | 是否加开关 | 不加；诊断走 CLI `classify` / `scan` |
| Q5 | 日报是否跟改 | 不动（已有「隐藏幕后任务」开关覆盖，语义不同） |
| Q6 | 主对话行是否留子 Agent 角注 | 不留 |

### 怎么算做好了

按拍板结果验收；若按推荐方案：

- 收件箱、菜单栏角标、系统通知、手机快照中均不再出现 `.subagent` 会话；
- 「幕后剑令」组仍正常显示 `externalRuntime` + `detached`；
- `InboxStateStore` 中已持久化的旧 subagent 状态不再参与角标计数（见约束）；
- 新增测试覆盖「subagent 完成不产生 attention state、不计入 unreadCount」；
- `./scripts/verify-mvp.sh` 以 `MVP_VERIFY=PASS` 结尾。

### 非目标

- 不改适配器的识别口径（README「识别口径」表不变）；
- 不建子 Agent ↔ 主对话的父子关联，不做主对话行角注；
- 不改 iOS 端（其「显示幕后任务」开关默认已关）。

### 约束

- `unreadCount` 数的是 `attentionStates` 而非 sessions——只过滤会话列表而不同层清理已持久化状态，角标仍会计数残留项；两者必须同层处理。
- 过滤层建议切在 AppState / MonitorService 之间，**不要**切在适配器层：CLI `classify` / `scan` 要继续看到全量，作为诊断面。
- 隐私红线照旧：不读消息正文、不上传数据。

### 依赖

- 六问拍板（维护者）；无代码依赖。

---

## T-02 幕后会话的角标与通知计数口径

### 意图

独立于 T-01：留在「幕后剑令」组的 `externalRuntime` / `detached` 复命，目前也计入菜单栏角标、也可触发系统通知。「幕后 = 不打扰」的分组语义与「计入待看」的计数行为矛盾，需要给幕后会话定一个明确的注意力口径。

### 怎么算做好了

- 拍板「幕后会话是否计角标 / 是否发系统通知」；
- 实现后菜单栏角标数与浮窗主列表可见待办一致，不再包含用户看不见的条目；
- 测试覆盖计数口径。

### 非目标

- 不改幕后组的折叠交互与组内「N 枚待看」表头（那是组内自述，与全局角标不同层）。

### 约束

- `unreadCount`（`AppState.swift:274`）需按 origin 过滤，而不是按 display bucket（bucket 依赖 `now`，不适合做计数依据）。

### 依赖

- T-01 拍板结果：若 Q1 最终选「整个幕后组移除」，本票自动消解。
