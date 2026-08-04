import Foundation
import JianlingShared

enum RuntimeSupportLevel: String {
    case guarded
    case found
    case available
    case verifying
}

enum RuntimeCatalogFilter: String, CaseIterable, Identifiable {
    case all
    case local
    case more

    var id: String { rawValue }
    func label(language: JianlingLanguage) -> String {
        switch self {
        case .all: return language.text("全部", "All")
        case .local: return language.text("这台 Mac", "On this Mac")
        case .more: return language.text("更多工具", "More tools")
        }
    }
}

struct RuntimeDescriptor: Identifiable, Hashable {
    let id: String
    let name: String
    let assetName: String
    let support: RuntimeSupportLevel
    let detectionPaths: [String]
    let detail: String
    let action: String

    var foundOnMac: Bool {
        if support == .guarded { return true }
        return detectionPaths.contains { FileManager.default.fileExists(atPath: NSString(string: $0).expandingTildeInPath) }
    }

    func statusLabel(language: JianlingLanguage) -> String {
        switch support {
        case .guarded: return language.text("正在守护", "Monitoring")
        case .found: return foundOnMac
            ? language.text("已在本机找到", "Found on this Mac")
            : language.text("还没接入", "Not connected")
        case .available: return foundOnMac
            ? language.text("已在本机找到", "Found on this Mac")
            : language.text("以后可接", "Available later")
        case .verifying: return language.text("还在确认", "Checking support")
        }
    }

    func localizedDetail(language: JianlingLanguage) -> String {
        guard language.usesEnglish else { return detail }
        switch id {
        case "craft": return "Craft conversations and scheduled runs return here when they finish."
        case "claude": return "Main conversations, subagents, and external runs stay neatly separated."
        case "codex": return "Conversations, automations, and subagents all return here when ready."
        case "newmax": return "Conversations, routine runs, and background agents return here with direct conversation links."
        case "workbuddy": return "Conversations and automations return here when ready, with direct links back to the original chat."
        case "opencode": return "OpenCode is installed, but Bladecall cannot read its task state yet."
        case "hermes": return "Hermes is installed. Its task log still needs a reliable adapter."
        case "cursor": return "Cursor is installed, but its agent results do not return to Bladecall yet."
        case "gemini": return "Gemini is installed. Reliable start and completion signals are still being verified."
        case "trae": return "TRAE is installed. Completion detection is still being verified."
        case "cherry": return "Cherry Studio is installed. Its task history is still being verified."
        case "kimi": return "Kimi Code can be added later; it is not monitored yet."
        case "kun": return "Kun Code, Design, and Write tasks can be added later."
        case "windsurf": return "Cascade results can return to Bladecall once an adapter is available."
        case "cline": return "Cline exposes clear task states and is a good candidate for a future adapter."
        case "copilot": return "Cloud tasks and local IDE tasks require separate connections."
        case "kiro": return "Kiro exposes useful completion signals and is a good future candidate."
        case "goose": return "A future adapter could cover Goose desktop, CLI, and subagent runs."
        case "aider": return "Aider results can return when the CLI finishes and waits for input."
        default: return detail
        }
    }

    func localizedAction(language: JianlingLanguage) -> String {
        statusLabel(language: language)
    }
}

enum RuntimeCatalog {
    static let all: [RuntimeDescriptor] = [
        RuntimeDescriptor(
            id: "craft", name: "Craft Agents", assetName: "craft.png", support: .guarded,
            detectionPaths: ["/Applications/Craft Agents.app"],
            detail: "Craft 里的对话和自动任务，做完后会回到这里。", action: "正在守护"
        ),
        RuntimeDescriptor(
            id: "claude", name: "Claude Code", assetName: "claude.png", support: .guarded,
            detectionPaths: ["/Applications/Claude.app"],
            detail: "主会话、子 Agent 和外部任务会分开收好。", action: "正在守护"
        ),
        RuntimeDescriptor(
            id: "codex", name: "Codex", assetName: "codex.png", support: .guarded,
            detectionPaths: ["/Applications/Codex.app"],
            detail: "会话、自动化和子 Agent 做完后都会回到这里。", action: "正在守护"
        ),
        RuntimeDescriptor(
            id: "newmax", name: "NewMax", assetName: "newmax.png", support: .guarded,
            detectionPaths: ["/Applications/NewMax.app", "~/.newmax/conversations"],
            detail: "会话、例行任务和幕后 Agent 会分开收好，并可直达原会话。", action: "正在守护"
        ),
        RuntimeDescriptor(
            id: "workbuddy", name: "WorkBuddy", assetName: "workbuddy.svg", support: .guarded,
            detectionPaths: ["/Applications/WorkBuddy.app", "~/.workbuddy/workbuddy.db"],
            detail: "会话和自动化任务做完后会回到这里，并可直达原会话。", action: "正在守护"
        ),
        RuntimeDescriptor(
            id: "opencode", name: "OpenCode", assetName: "opencode.png", support: .found,
            detectionPaths: ["/Applications/OpenCode.app", "~/.local/bin/opencode"],
            detail: "本机已经找到 OpenCode，但剑令还看不到它的任务状态。", action: "还没接入"
        ),
        RuntimeDescriptor(
            id: "hermes", name: "Hermes Agent", assetName: "hermes.png", support: .found,
            detectionPaths: ["/Applications/Hermes.app", "/Applications/Hermes Studio.app", "~/.hermes"],
            detail: "本机已经找到 Hermes，下一步是确认它的任务记录是否稳定。", action: "还没接入"
        ),
        RuntimeDescriptor(
            id: "cursor", name: "Cursor", assetName: "cursor.png", support: .found,
            detectionPaths: ["/Applications/Cursor.app"],
            detail: "本机已经找到 Cursor，但它的 Agent 结果还不会回到剑令。", action: "还没接入"
        ),
        RuntimeDescriptor(
            id: "gemini", name: "Gemini CLI", assetName: "gemini.png", support: .found,
            detectionPaths: ["/Applications/Gemini.app", "~/.npm-global/bin/gemini"],
            detail: "本机已经找到 Gemini，正在确认可靠的开始和完成信号。", action: "还没接入"
        ),
        RuntimeDescriptor(
            id: "trae", name: "TRAE", assetName: "trae.png", support: .found,
            detectionPaths: ["/Applications/Trae.app"],
            detail: "本机已经找到 TRAE，完成信号还在验证。", action: "还在验证"
        ),
        RuntimeDescriptor(
            id: "cherry", name: "Cherry Studio", assetName: "cherry-studio.png", support: .found,
            detectionPaths: ["/Applications/Cherry Studio.app"],
            detail: "本机已经找到 Cherry Studio，任务记录还在验证。", action: "还在验证"
        ),
        RuntimeDescriptor(
            id: "kimi", name: "Kimi Code CLI", assetName: "kimi.png", support: .available,
            detectionPaths: ["~/.local/bin/kimi", "~/.npm-global/bin/kimi"],
            detail: "以后可以接入 Kimi Code；当前还没有开始监控。", action: "以后可接"
        ),
        RuntimeDescriptor(
            id: "kun", name: "Kun", assetName: "kun.png", support: .available,
            detectionPaths: ["/Applications/Kun.app"],
            detail: "以后可以把 Kun 的 Code、Design、Write 任务收进来。", action: "以后可接"
        ),
        RuntimeDescriptor(
            id: "windsurf", name: "Windsurf", assetName: "windsurf.svg", support: .available,
            detectionPaths: ["/Applications/Windsurf.app"],
            detail: "以后可以在 Cascade 做完一轮时，把结果收进剑令。", action: "以后可接"
        ),
        RuntimeDescriptor(
            id: "cline", name: "Cline", assetName: "cline.png", support: .available,
            detectionPaths: [],
            detail: "Cline 的任务状态比较清楚，适合后续接入。", action: "以后可接"
        ),
        RuntimeDescriptor(
            id: "copilot", name: "GitHub Copilot", assetName: "github-copilot.svg", support: .available,
            detectionPaths: [],
            detail: "云端任务和本地 IDE 的入口不同，需要分别处理。", action: "以后可接"
        ),
        RuntimeDescriptor(
            id: "kiro", name: "Kiro", assetName: "kiro.png", support: .available,
            detectionPaths: ["/Applications/Kiro.app"],
            detail: "Kiro 的完成信号比较清楚，适合后续接入。", action: "以后可接"
        ),
        RuntimeDescriptor(
            id: "goose", name: "Goose", assetName: "goose.png", support: .available,
            detectionPaths: ["/Applications/Goose.app", "~/.local/bin/goose"],
            detail: "以后可以覆盖 Goose 的桌面任务、CLI 和子 Agent。", action: "以后可接"
        ),
        RuntimeDescriptor(
            id: "aider", name: "Aider", assetName: "aider.png", support: .available,
            detectionPaths: ["~/.local/bin/aider", "/opt/homebrew/bin/aider"],
            detail: "以后可以在 Aider 做完并等待输入时，把结果收回来。", action: "以后可接"
        ),
    ]

    static func values(for filter: RuntimeCatalogFilter) -> [RuntimeDescriptor] {
        switch filter {
        case .all: return all
        case .local: return all.filter(\.foundOnMac)
        case .more: return all.filter { !$0.foundOnMac }
        }
    }
}
