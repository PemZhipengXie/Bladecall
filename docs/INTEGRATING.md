# Integrate any agent in one line · 任何 agent 一行接入

Bladecall watches five runtimes natively. **Every other agent can report itself** by
writing one small JSON file — no adapter, no reverse engineering, no SDK.

剑令原生守护五个运行环境。**其余任何 agent 都可以自报**：写一个小 JSON 文件即可接入——
不需要适配器、不需要逆向、不需要 SDK。

## The drop protocol · 投递协议

Write (and overwrite) one file per task:

```
~/.jianling/drops/<tool>/<sessionID>.json
```

```json
{
  "schemaVersion": 1,
  "title": "Refactor login flow",
  "status": "started",
  "timestamp": "2026-08-04T12:00:00Z",
  "projectPath": "/path/to/repo",
  "origin": "interactive"
}
```

| Field | Required | Values / notes |
| --- | --- | --- |
| `schemaVersion` | yes | `1` |
| `status` | yes | `started` → `progress`* → `done` \| `failed`（\*可选心跳） |
| `timestamp` | yes | ISO 8601。`done` 的时间戳同时是完成指纹的种子：**同一次完成重复写入必须保持同一时间戳**，换一轮新任务就换新时间戳。 |
| `title` | recommended | Task title, shown in the inbox. 不要放敏感内容。 |
| `projectPath` | optional | Absolute repo path, used for grouping and reports. |
| `origin` | optional | `interactive`(default) \| `scheduled`（进例行收件箱）\| `subagent`（默认折叠为幕后） |

Rules the protocol enforces · 协议强制的规则：

- **Identity comes from the path**, not the payload — `<tool>` directory name is the slug
  (lowercase `a-z0-9._-`), `<sessionID>` file name is the session. 载荷冒充不了别的工具。
- Drops over **64 KB** are rejected; keep it to task state, never message bodies.
- A `done`/`failed` drop rings the inbox **once** per timestamp. A `started` task that
  never reports back simply ages out of the active list — silence is not completion.

## Ways to write the drop · 三种写法

**1. Shell (any agent that can run commands · 任何能跑命令的 agent):**

```bash
mkdir -p ~/.jianling/drops/myagent && cat > ~/.jianling/drops/myagent/task-42.json <<EOF
{"schemaVersion":1,"title":"Build the report","status":"done","timestamp":"$(date -u +%FT%TZ)"}
EOF
```

**2. The official CLI (clone this repo once) · 官方 CLI:**

```bash
swift run -c release completion-bell-cli task \
  --tool myagent --session task-42 --title "Build the report" --status done
```

**3. A deterministic hook (best) · 确定性 hook（最佳）:**

Tools with hook systems don't need to *remember* to report. Claude Code example —
`~/.claude/settings.json` Stop hook fires on every turn end:

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command":
      "mkdir -p ~/.jianling/drops/claude-hook && printf '{\"schemaVersion\":1,\"title\":\"Claude Code turn\",\"status\":\"done\",\"timestamp\":\"%s\"}' \"$(date -u +%FT%TZ)\" > ~/.jianling/drops/claude-hook/$PPID.json" }] }]
  }
}
```

（Claude Code 本身已被原生守护，此例仅演示 hook 形态；请把它套用到你自己的工具上。）

## The prompt to give your agent · 给你的 agent 的提示词

Paste this once into any agent's instructions / rules file:

> 当你开始一个较长任务时，向 `~/.jianling/drops/<你的名字小写>/<会话id>.json` 写入
> `{"schemaVersion":1,"title":"<任务标题>","status":"started","timestamp":"<ISO8601 当前时间>"}`；
> 任务完成时把同一文件的 `status` 改为 `done`（失败则 `failed`）并更新 `timestamp`。
> 只写任务状态，不要写对话内容。

## Honesty tier · 诚实档位

Self-reported sessions show as **自报 / self-report** in the inbox — deliberately distinct
from **正在守护 / monitored**:

- *Monitored* = Bladecall observes the tool's own local records; it cannot miss a completion.
- *Self-report* = the agent promised to tell us; a crash or a forgotten update means the
  task quietly ages out instead of ringing.

自报会话在收件箱里明确标注「自报」，与「正在守护」区分——守护是我们观察到的事实，
自报是对方的承诺。崩溃或忘记上报的任务会安静地淡出，不会假装完成。

## Want native, watched support? · 想要原生守护？

That's a pull adapter: Bladecall reads your tool's local session files at the source.
PRs welcome — implement `SessionAdapter` in `Sources/CompletionBellCore/`
(see `CraftAdapter.swift` for the smallest example), document the completion signal, and
include a redacted fixture. The bar: a reliable, local, observable completion signal —
no screenshot scraping, no browser automation, no message bodies.

原生守护 = 拉取适配器。欢迎提 PR：在 `Sources/CompletionBellCore/` 实现 `SessionAdapter`
（最小样例见 `CraftAdapter.swift`），写清完成判断口径，附脱敏样本。门槛只有一条：
可靠、本地、可观察的完成信号——不截屏、不自动化浏览器、不读消息正文。
