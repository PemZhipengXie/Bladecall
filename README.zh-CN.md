<p align="center">
  <a href="./README.md">English</a> · <a href="./README.zh-CN.md"><b>简体中文</b></a>
</p>

<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="剑令 Bladecall — 本地优先的 macOS 菜单栏应用，把多个本地 AI 编程工具的完成结果收回一个安静的收件箱">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-211914?style=flat-square" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-6-A43135?style=flat-square" alt="Swift 6">
  <img src="https://img.shields.io/badge/license-PolyForm_Noncommercial_1.0.0-4B3B31?style=flat-square" alt="PolyForm Noncommercial 1.0.0">
  <img src="https://img.shields.io/badge/EN%20%2F%20%E4%B8%AD%E6%96%87-bilingual-9D282B?style=flat-square" alt="中英双语">
</p>

**剑令**（Bladecall）是一款本地优先的 macOS 菜单栏应用，适合同时使用多个 AI 编程工具的人。它观察任务状态，把例行任务与幕后运行分开；结果完成后，只留下一个安静的未读信号，让你不必反复巡逻每个对话窗口。

> **人掌令，AI 行剑。** · You stay in command. AI does the work.

<p align="center">
  <img src="./assets/readme/lifecycle.svg" width="100%" alt="剑令的一条闭环：你发令，AI 行剑，结果作为安静的未读信号复命，由你决定何时归鞘">
</p>

多数多 Agent 工作流仍然要求人不停检查窗口。剑令把这个关系反过来——一条任务只走**一个清晰的闭环**：你发令，AI 行剑，结果完成后作为安静的未读信号复命，再由**你**决定何时查看、何时归鞘。剑令不会把每一个本地 Session 都冒充成重要会话：定时任务、子 Agent 和脱离宿主界面的运行过程分别归类；没有可靠本地事件源的工具，绝不会被标成「已经支持」。

## 你会得到什么

- **一个结果收件箱**：统一接收 Codex、Claude Code、Craft Agents、NewMax 和 WorkBuddy 的任务状态。
- **清晰的闭环**：`行剑中 → 复命未阅 → 已阅待决 → 归鞘`，一条任务一条命。
- **例行剑令**：定时任务单独呈现，因为它们的结果仍然值得查看。
- **幕后剑令**：子 Agent 与技术运行过程默认折叠，减少噪音。
- **默认安静**：不强迫开启系统通知；声音与动效均可选择。
- **剑气额度**：只展示 Codex 与 Claude Code 实际返回的额度窗口，不保存账户 Token。
- **剑迹日报**：以可缩放时间轴查看 App 前台时间、任务运行、完成节点和处理等待。
- **中英双语**：Mac、日报、通知与 iPhone 端使用同一套语言体系。

## 运行环境

**正在守护** —— 具备可靠本地完成信号，实时监听：

<p align="center">
  <img src="./Sources/CompletionBell/Resources/Runtimes/craft.png" height="48" alt="Craft Agents">&nbsp;&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/claude.png" height="48" alt="Claude Code">&nbsp;&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/codex.png" height="48" alt="Codex">&nbsp;&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/newmax.png" height="48" alt="NewMax">&nbsp;&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/workbuddy.svg" height="48" alt="WorkBuddy">
</p>
<p align="center">
  <sub><b>Craft Agents</b> · <b>Claude Code</b> · <b>Codex</b> · <b>NewMax</b> · <b>WorkBuddy</b></sub>
</p>

**已识别** —— 剑令也会在 App 里显示这些工具；部分已在本机发现，部分在路线图上。但**尚未**对它们声称可靠的完成监控：

<p align="center">
  <img src="./Sources/CompletionBell/Resources/Runtimes/hermes.png" height="34" alt="Hermes">&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/cursor.png" height="34" alt="Cursor">&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/gemini.png" height="34" alt="Gemini CLI">&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/trae.png" height="34" alt="TRAE">&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/opencode.png" height="34" alt="OpenCode">&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/cherry-studio.png" height="34" alt="Cherry Studio">&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/kimi.png" height="34" alt="Kimi">&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/kun.png" height="34" alt="Kun">&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/windsurf.svg" height="34" alt="Windsurf">&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/cline.png" height="34" alt="Cline">&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/github-copilot.svg" height="34" alt="GitHub Copilot">&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/kiro.png" height="34" alt="Kiro">&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/goose.png" height="34" alt="Goose">&nbsp;&nbsp;&nbsp;
  <img src="./Sources/CompletionBell/Resources/Runtimes/aider.png" height="34" alt="Aider">
</p>
<p align="center">
  <sub>Hermes · Cursor · Gemini CLI · TRAE · OpenCode · Cherry Studio · Kimi · Kun · Windsurf · Cline · GitHub Copilot · Kiro · Goose · Aider</sub>
</p>

只有具备可靠本地事件源，剑令才会把一个工具标为「正在守护」——完成判断不依赖截图识别，也不依赖浏览器自动操作。

### 任何 agent 一行接入

会写文件的 agent 就能自报进收件箱——不需要适配器、不需要 SDK：

```bash
mkdir -p ~/.jianling/drops/myagent && printf '{"schemaVersion":1,"title":"生成报表","status":"done","timestamp":"%s"}' "$(date -u +%FT%TZ)" > ~/.jianling/drops/myagent/task-42.json
```

自报会话以明确的「**自报**」档位呈现，与「正在守护」严格区分。完整协议、CLI 与 hook 示例见 [docs/INTEGRATING.md](./docs/INTEGRATING.md)；想为你的工具争取原生守护，同一份文档写明了适配器门槛，欢迎提 PR。

<details>
<summary>每个工具的完成判断口径</summary>

| 工具 | 完成判断 |
| --- | --- |
| **Craft Agents** | 本轮 user 之后出现最新一条非中间态 assistant 事件。 |
| **Claude Code** | 最新 assistant 消息以 `stop_reason=end_turn` 结束。 |
| **Codex** | 出现 `event_msg.payload.type=task_complete`，并按 `turn_id` 去重。 |
| **NewMax** | 最新 assistant 快照已有最终结果，且没有仍在运行的工具调用。 |
| **WorkBuddy** | 本轮最新 assistant 消息的 `status=completed`。 |

</details>

## 监控机制

剑令通过 FSEvents 监听各运行环境的本地会话目录。文件发生变化后先做防抖，只重扫受影响的适配器；低频全量对账负责补回遗漏事件。FSEvents 不可用时，会自动降级为轮询。

```text
本地会话事件
      ↓
运行环境适配器  →  任务状态对账
      ↓
安静收件箱  +  剑迹日报  +  可选设备同步
```

<p align="center">
  <img src="./assets/readme/settings-en.png" width="90%" alt="剑令设置页：语言、主题、字体、窗口大小和安静提醒选项">
</p>

## 构建与运行

**环境要求：** macOS 13 Ventura 或更新版本 · Swift 6 工具链

```bash
git clone https://github.com/PemZhipengXie/Bladecall.git
cd Bladecall
./scripts/verify-mvp.sh      # 测试 + simulate + doctor + 打包校验
./scripts/install-local.sh   # 安装到 ~/Applications 并注册 LaunchAgent
```

随时用 `./scripts/uninstall-local.sh` 完整移除。

## 隐私边界

- 活动数据默认只留在你的设备上，不上传。
- 剑令**不**保存、不展示、不上传对话消息正文。
- 日志和日报只包含时间、运行环境、任务标题、项目名、来源和状态变化。
- 剑气沿用本机已有登录，只读取剩余额度和恢复时间，**不**保存账户 Token。
- 点击任务行会激活宿主 App；只有运行环境提供稳定入口时，才会进一步直达具体对话。
- 没有可靠本地事件源的网页会话，不会被伪装成可监控对象。

## iPhone 伴侣应用

iPhone App 与 Widget 已移入独立私有仓库，计划作为闭源 App Store 产品以很低的一次性价格提供（目标 **US$0.99** 或对应地区价格，最终售价由 App Store Connect 决定）。源码公开的 Mac 端可以独立使用；手机端只是可选伴侣，让你离开 Mac 后也能查看和处理已经回来的结果。

## License

由于禁止商业使用，剑令应称为「**源码公开（source-available）**」，而不是「开源软件」：

- **macOS App 与通用核心**：[PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/)。允许个人和其他非商业用途查看、修改与使用；任何商业使用都需要另行取得书面授权。
- **iPhone App 与 Widget**：闭源，通过 App Store 单独分发，源码放在独立私有仓库。
- **Bladecall / 剑令名称、Logo、音效和品牌资产**：保留全部权利；软件 License 不等于品牌使用许可。

完整边界见 [LICENSING.md](./LICENSING.md)。

## 当前限制

- 各运行环境的本地文件格式不是稳定公开 API，工具升级后可能需要更新适配器。
- 不同运行环境对「宿主窗口可见性」的支持精度并不一致。
- 剑令可以可靠判断结果是否完成，但不能因此推断用户当前正在阅读哪个具体对话。

## 参与贡献

欢迎提交 Bug 复现、适配器研究、脱敏测试样本、无障碍改进和隐私优先的性能优化。请**勿**在 Issue 中上传消息正文、凭证或私人 Session 文件。

---

<p align="center"><b>任务发出去，结果回来找你。</b><br><sub>Send the work out. Bring the results home.</sub></p>
