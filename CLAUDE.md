# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

剑令（英文工作品牌 **Bladecall**）是一个 macOS 菜单栏 + 置顶浮窗应用：监听本机 AI 编程工具（Craft Agents、Claude Code、Codex、NewMax、WorkBuddy）的会话文件，把任务完成事件收进一个安静的本地收件箱，并生成每日 HTML/Markdown 日报。iPhone App 与专属 Widget 已迁入独立私有仓库；当前仓库只保留 macOS App 与供手机端依赖的共享模型、配对和 CloudKit 桥接。隐私边界：只读本地文件、不读消息正文、不上传数据。

## 常用命令

```bash
swift build                                # 调试构建（Swift Package）
swift run completion-bell-tests            # 运行全部自动测试（自定义测试可执行文件，非 XCTest）
swift run -c release completion-bell-cli scan      # 扫描各适配器会话
swift run -c release completion-bell-cli doctor    # 检查各工具数据目录是否存在
./scripts/verify-mvp.sh                    # 完整验收线：测试 + simulate + doctor + scan + 打包 + 音效校验
./scripts/build-app.sh                     # 打包 dist/剑令.app（ad-hoc 签名）
./scripts/install-local.sh                 # 安装到 ~/Applications 并注册 LaunchAgent
./scripts/uninstall-local.sh               # 完整移除
./scripts/generate-xcode-project.sh        # XcodeGen 生成仅含 macOS App 的 Jianling.xcodeproj
```

CLI 子命令：`doctor | scan | simulate | benchmark | idle-bench | running | classify | report | report-en`（见 `Sources/CompletionBellCLI/main.swift`）。`idle-bench` 连扫 12 轮并输出每轮 `unchanged` 判定与变化会话归因，用于验证空闲短路。

### 测试机制（重要）

测试不是 XCTest：`Sources/CompletionBellTests/main.swift` 是单文件测试可执行目标，所有测试是文件末尾 `tests` 数组中的 `(名称, 闭包)` 元组，用 `expect`/`unwrap` 断言，一次全部运行、无法按名筛选。新增测试 = 向该数组追加元组。`Tests/` 目录是空壳，真正的测试都在这个文件里。

## 架构

Swift Package（swift-tools 6.0，语言模式 v5），macOS 13+ / iOS 17+。目标依赖关系：

- **CompletionBellCore** — 平台无关核心，无内部依赖。包含：
  - 适配器（`CraftAdapter`、`ClaudeCodeAdapter`、`CodexAdapter`、`NewMaxAdapter`、`WorkBuddyAdapter`）：实现 `SessionAdapter` 协议（含 `watchRoots` 监听目录），各自解析对应工具的本地会话目录（`~/.craft-agent/workspaces`、`~/.claude/projects`、`~/.codex/sessions`、`~/.newmax/conversations`、`~/.workbuddy/projects`），产出 `SessionSnapshot`。文件未变化复用解析缓存；任一适配器异常不影响其他适配器（验收线要求）。
  - 事件驱动监控（macOS 应用侧）：`FileEventMonitor`（FSEvents + Codex WAL vnode）→ `ScanScheduler`（Core，防抖 500ms/适配器限流 2s/对账 90s，纯逻辑可测）→ `MonitorService.scan(only:)` 只扫脏适配器、未扫者复用上轮结果；`ScanChangeDetector` + `DisplayFingerprint` 双层短路保证无变化轮次零写盘零广播零 UI 重算。FSEvents 不可用自动降级 5 秒轮询。
  - `CompletionDetector`：用 `completionFingerprint` 去重；首次扫描只建历史基线、不发提醒。
  - `InboxStateStore`：状态链 `行剑中 → 复命未阅 → 已阅待决 → 归鞘` 的跨重启持久化。
  - 会话来源分类 `SessionOrigin`：interactive（交互）/ routine（例行剑令，定时任务）/ background（幕后剑令：子 Agent、Multica、宿主不可见 Session）。日报与收件箱按此过滤。
  - `ActivityLog` / `DailyReportGenerator` / `DailyReportHTMLRenderer`：日报生成。HTML 模板带版本标记（`jianling-report-template`），用 `isCurrentHTMLTemplate` 判断旧报告是否需要重新生成——改模板时必须同步升版本号。
  - `QuotaModels`：「剑气」额度解析（各平台真实额度窗口，读不到真实数据时隐藏）。
- **JianlingShared** — Mac 与私有手机端共享的模型、偏好、存储。
- **JianlingSync**（依赖 Shared）— 同网 PIN 配对与局域网传输。
- **JianlingCloudSync**（依赖 Shared）— CloudKit 私有库同步。
- **CompletionBell**（macOS 应用，依赖以上全部）— `AppDelegate` + `AppState` 驱动；菜单面板与置顶浮窗复用同一个紧凑视图（`Views.swift`）；`QuotaMonitorService`、`NotificationService`（默认静默，不请求通知权限）、`SettingsView`、设计令牌在 `JianlingDesign.swift`。
- **CompletionBellCLI** / **CompletionBellTests** — 上述 CLI 与测试可执行目标。

iPhone App 与 Widget 源码不在本仓库。`project.yml` 只生成 macOS App 工程；共享模块继续作为 Swift Package 产品提供给相邻的私有移动端仓库。

## 各工具完成信号口径

改动适配器前先对照 README「识别口径」表：Craft 看 JSONL 尾部非中间态 assistant；Claude Code 看 `stop_reason=end_turn`；Codex 看 `task_complete` 事件按 `turn_id` 去重；NewMax 看最新 assistant 快照无运行中工具调用；WorkBuddy 看本轮最新 assistant 的 `status=completed`（SQLite 仅用于标题/早期状态/自动化分类）。

## 数据位置

- 日报输出：`~/Documents/AI会话监控浮窗/日报/`（即本仓库的 `日报/` 目录）
- 活动事件：`~/Library/Application Support/CompletionBell/activity.jsonl`
- 诊断日志：`~/Library/Logs/CompletionBell/app.jsonl`

## 约定

- 双语产品语言：中文为主，英文用 Bladecall 品牌语（规范见 `docs/剑令_英文品牌与本地化规范.md`）；任务原标题始终保持原文，不翻译。
- 隐私红线：不读取/记录消息正文，不上传数据，剑气不保存账号或 Token；没有可靠本地事件源的工具不能假装可监控（设置页区分「正在守护 / 已发现 / 可加入」三种事实）。
- 验收改动用 `./scripts/verify-mvp.sh`，期望输出以 `MVP_VERIFY=PASS` 结尾。

## Agent skills

### Issue tracker

Issues 用本仓库的 GitHub Issues（gh CLI）管理。见 `docs/agents/issue-tracker.md`。

### Triage labels

五个规范 triage 标签按默认词表使用（needs-triage / needs-info / ready-for-agent / ready-for-human / wontfix）。见 `docs/agents/triage-labels.md`。

### Domain docs

单上下文布局：根目录 `CONTEXT.md` + `docs/adr/`。见 `docs/agents/domain.md`。
