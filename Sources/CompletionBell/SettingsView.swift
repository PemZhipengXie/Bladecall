import AppKit
import CompletionBellCore
import JianlingShared
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case energy
    case runtimes
    case devices
    case profile
    case about

    var id: String { rawValue }

    func title(language: JianlingLanguage) -> String {
        switch self {
        case .general: return language.text("通用", "General")
        case .energy: return language.text("剑气", "Energy")
        case .runtimes: return language.text("运行环境", "AI tools")
        case .devices: return language.text("iPhone 与 Widget", "iPhone & Widget")
        case .profile: return language.text("个人资料", "Profile")
        case .about: return language.text("关于剑令", "About Bladecall")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "switch.2"
        case .energy: return "bolt.horizontal.circle"
        case .runtimes: return "square.stack.3d.up"
        case .devices: return "iphone.and.arrow.forward"
        case .profile: return "person.crop.circle"
        case .about: return "seal"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var section: SettingsSection = .general
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var navigation: SettingsNavigation
    @State private var showsQuitConfirmation = false

    private var palette: JianlingPalette { JianlingPalette(state.appearance) }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width < 620 {
                    compactLayout
                } else {
                    regularLayout
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(palette.background.ignoresSafeArea())
        .preferredColorScheme(.light)
        .jianlingFontScale(state.fontScale)
        .environment(\.locale, state.language.locale)
        .confirmationDialog(
            state.text("退出剑令？", "Quit Bladecall?"),
            isPresented: $showsQuitConfirmation,
            titleVisibility: .visible
        ) {
            Button(state.text("退出剑令", "Quit Bladecall"), role: .destructive) {
                state.onQuit?()
            }
            Button(state.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(state.text("退出后将停止监控；下次仍可从“应用程序”打开。", "Monitoring stops until you open Bladecall again."))
        }
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(palette.line).frame(width: 1)
            sectionContent
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                JianlingSeal(size: 30)
                Text(state.language.productName)
                    .font(.custom("STKaiti", size: 19).weight(.semibold))
                    .foregroundStyle(palette.text)
                Spacer(minLength: 8)
                Menu {
                    ForEach(SettingsSection.allCases) { item in
                        Button {
                            navigation.section = item
                        } label: {
                            Label(item.title(language: state.language), systemImage: item.symbol)
                        }
                    }
                } label: {
                    Label(
                        navigation.section.title(language: state.language),
                        systemImage: navigation.section.symbol
                    )
                    .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button { showsQuitConfirmation = true } label: {
                    Image(systemName: "power")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.seal)
                .help(state.text("退出剑令", "Quit Bladecall"))
                .accessibilityLabel(state.text("退出剑令", "Quit Bladecall"))
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .background(palette.background)

            Rectangle().fill(palette.line).frame(height: 1)
            sectionContent
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        Group {
            switch navigation.section {
            case .general: GeneralSettingsPage(state: state)
            case .energy: EnergySettingsPage(state: state)
            case .runtimes: RuntimeSettingsPage(state: state)
            case .devices: DeviceSettingsPage(state: state)
            case .profile: ProfileSettingsPage(state: state)
            case .about: AboutSettingsPage(state: state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surface)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                JianlingSeal(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.language.productName)
                        .font(.custom("STKaiti", size: 20).weight(.semibold))
                        .foregroundStyle(palette.text)
                    Text(state.text("人掌令，AI 行剑", "You stay in command"))
                        .jianlingFont(state.appearance, size: 8)
                        .foregroundStyle(palette.tertiaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 76)

            VStack(spacing: 5) {
                ForEach(SettingsSection.allCases) { item in
                    Button {
                        navigation.section = item
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 18)
                            Text(item.title(language: state.language))
                                .fontWeight(navigation.section == item ? .semibold : .regular)
                            Spacer()
                        }
                        .jianlingFont(state.appearance, size: 12)
                        .foregroundStyle(navigation.section == item ? palette.text : palette.secondaryText)
                        .padding(.horizontal, 9)
                        .frame(height: 38)
                        .background(navigation.section == item ? palette.raised : Color.clear)
                        .overlay {
                            if navigation.section == item {
                                RoundedRectangle(cornerRadius: palette.cornerSmall)
                                    .stroke(palette.line, lineWidth: state.appearance == .pixel ? 2 : 0.6)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: palette.cornerSmall))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.text("数据留在本机", "Data stays local"))
                        .fontWeight(.semibold)
                        .foregroundStyle(palette.secondaryText)
                    Text(state.text("只看状态，不看内容", "Status only, never message content"))
                        .foregroundStyle(palette.tertiaryText)
                }

                Button { showsQuitConfirmation = true } label: {
                    Label(state.text("退出剑令", "Quit Bladecall"), systemImage: "power")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.seal)
            }
            .jianlingFont(state.appearance, size: 9)
            .padding(14)
        }
        .frame(width: 164)
        .background(palette.background)
    }
}

private struct GeneralSettingsPage: View {
    @ObservedObject var state: AppState
    @State private var previewPulse = false

    private var palette: JianlingPalette { JianlingPalette(state.appearance) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(
                    title: state.text("通用", "General"),
                    subtitle: state.text("AI 做完会在这里留个信号，不打断你手头的事。", "AI results leave a quiet signal here without interrupting your work."),
                    appearance: state.appearance
                )

                settingsCard(state.text("显示", "Display")) {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(state.text("显示方式", "Display mode"))
                                .fontWeight(.semibold)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                                PresentationModeTile(
                                    title: state.text("浮窗", "Floating"),
                                    detail: state.text("始终显示，可拖动缩放", "Always visible and resizable"),
                                    symbol: "macwindow",
                                    selected: state.presentationMode == .floating,
                                    enabled: true,
                                    appearance: state.appearance
                                ) { state.presentationMode = .floating }
                                PresentationModeTile(
                                    title: state.text("刘海", "Notch"),
                                    detail: state.text("刘海两翼；外接屏显示顶部胶囊", "Notch wings or a top capsule"),
                                    symbol: "laptopcomputer",
                                    selected: state.presentationMode == .notch,
                                    enabled: true,
                                    appearance: state.appearance
                                ) { state.presentationMode = .notch }
                                PresentationModeTile(
                                    title: state.text("右侧", "Edge"),
                                    detail: state.text("收在右缘，悬停展开", "Hover at the right edge"),
                                    symbol: "sidebar.right",
                                    selected: state.presentationMode == .rightEdge,
                                    enabled: true,
                                    appearance: state.appearance
                                ) { state.presentationMode = .rightEdge }
                            }
                        }

                        if state.presentationMode == .notch && state.notchScreenChoices.count > 1 {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(state.text("刘海所在显示器", "Notch display"))
                                    Text(state.text("无刘海的外接屏会显示为顶部胶囊", "External displays use the top capsule"))
                                        .jianlingFont(state.appearance, size: 10)
                                        .foregroundStyle(palette.tertiaryText)
                                }
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { state.notchScreenID ?? "" },
                                    set: { state.notchScreenID = $0.isEmpty ? nil : $0 }
                                )) {
                                    Text(state.text("自动（主屏）", "Automatic (main)")).tag("")
                                    ForEach(state.notchScreenChoices) { screen in
                                        Text(screen.title).tag(screen.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 220)
                            }
                        }

                        if state.presentationMode == .rightEdge {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(state.text("侧签大小", "Tag size"))
                                    Text(state.text("越大越易读，也越占屏幕边缘", "Larger reads easier but takes more edge"))
                                        .jianlingFont(state.appearance, size: 10)
                                        .foregroundStyle(palette.tertiaryText)
                                }
                                Spacer()
                                Picker("", selection: $state.edgeTagSize) {
                                    Text(state.text("小", "S")).tag(EdgeTagSize.small)
                                    Text(state.text("中", "M")).tag(EdgeTagSize.medium)
                                    Text(state.text("大", "L")).tag(EdgeTagSize.large)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 150)
                            }
                        }

                        if state.presentationMode == .rightEdge && state.edgeScreenChoices.count > 1 {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(state.text("侧签所在显示器", "Tag display"))
                                    Text(state.text("多屏时选择半枚剑令出现在哪块屏的右缘", "Pick which display shows the edge tag"))
                                        .jianlingFont(state.appearance, size: 10)
                                        .foregroundStyle(palette.tertiaryText)
                                }
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { state.edgeScreenID ?? "" },
                                    set: { state.edgeScreenID = $0.isEmpty ? nil : $0 }
                                )) {
                                    Text(state.text("自动（主屏）", "Automatic (main)")).tag("")
                                    ForEach(state.edgeScreenChoices) { screen in
                                        Text(screen.title).tag(screen.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 220)
                            }
                        }

                        Divider().overlay(palette.line)

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(state.text("语言", "Language"))
                                    .fontWeight(.semibold)
                                Text(state.text("界面、通知和打开的日报会一起切换。", "Changes the interface, notifications, and the report you open."))
                                    .foregroundStyle(palette.tertiaryText)
                            }
                            Spacer()
                            Picker(state.text("语言", "Language"), selection: $state.language) {
                                ForEach(JianlingLanguage.allCases) { language in
                                    Text(language.displayName(in: state.language)).tag(language)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 184)
                        }

                        Divider().overlay(palette.line)

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("主题")
                                    .fontWeight(.semibold)
                                Text("选清爽的现代风，或复古的像素武侠风。")
                                    .foregroundStyle(palette.tertiaryText)
                            }
                            Spacer()
                            Picker("主题", selection: $state.appearance) {
                                ForEach(JianlingAppearance.allCases) { appearance in
                                    Text(appearance.label(language: state.language)).tag(appearance)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 184)
                        }

                        Divider().overlay(palette.line)

                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("字体大小")
                                    .fontWeight(.semibold)
                                Text("\(Int((state.fontScale * 100).rounded()))%")
                                    .foregroundStyle(palette.tertiaryText)
                            }
                            .frame(width: 86, alignment: .leading)
                            Slider(value: $state.fontScale, in: 0.85...1.25, step: 0.05)
                        }

                        Divider().overlay(palette.line)

                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("浮窗大小")
                                    .fontWeight(.semibold)
                                Text("拖动窗口边缘或右下角，自由调整大小。")
                                    .foregroundStyle(palette.tertiaryText)
                            }
                            Spacer()
                            Button("恢复默认字体") { state.fontScale = 1 }
                            .buttonStyle(.bordered)
                        }

                        Divider().overlay(palette.line)

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(state.text("浮窗置顶", "Keep window on top"))
                                    .fontWeight(.semibold)
                                Text(state.text("保持浮窗悬浮在其他窗口之上；关闭后会被普通窗口盖住。", "Float above other windows; turn off to let normal windows cover it."))
                                    .foregroundStyle(palette.tertiaryText)
                            }
                            Spacer()
                            Toggle(state.text("浮窗置顶", "Keep window on top"), isOn: $state.floatingAlwaysOnTop)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }

                        Divider().overlay(palette.line)

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(state.text("在 Dock 显示图标", "Show Dock icon"))
                                    .fontWeight(.semibold)
                                Text(state.text("菜单栏被刘海或图标挤满时，可从 Dock 找回剑令。", "A fallback entry when the notch or a crowded menu bar hides the status icon."))
                                    .foregroundStyle(palette.tertiaryText)
                            }
                            Spacer()
                            Toggle(state.text("在 Dock 显示图标", "Show Dock icon"), isOn: $state.dockIconVisible)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                    }
                }

                settingsCard(state.text("复命提醒", "Result signals")) {
                    VStack(spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("出剑与剑鸣")
                                    .fontWeight(.semibold)
                                Text(state.noticeStyle == .quiet
                                    ? state.text("动作保持静默，AI 做完只留下未读光点。", "Keep actions quiet; completed work only leaves an unread signal.")
                                    : state.text("任务发出时响出剑声；点击行剑中或“阅”时响剑鸣。", "Play a draw sound when work starts, and a sword ring when you open active or unread work."))
                                    .foregroundStyle(palette.tertiaryText)
                            }
                            Spacer()
                            Picker("提醒方式", selection: $state.noticeStyle) {
                                ForEach(CompletionNoticeStyle.allCases) { style in
                                    Text(style.label(language: state.language)).tag(style)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 184)
                        }

                        Divider().overlay(palette.line)

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("归鞘声")
                                    .fontWeight(.semibold)
                                Text("点“归”时响一下轻短的收束声。")
                                    .foregroundStyle(palette.tertiaryText)
                            }
                            Spacer()
                            Toggle("归鞘声", isOn: $state.sheathSoundEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }

                        HStack(spacing: 8) {
                            Button("试听出剑") { state.previewDispatchSound() }
                                .buttonStyle(.bordered)
                            Button("试听剑鸣") { state.previewSwordChime() }
                                .buttonStyle(.bordered)
                            Button("试听归鞘") { state.previewSheathSound() }
                                .buttonStyle(.bordered)
                            Button("试听推") { state.previewSwordPushSound() }
                                .buttonStyle(.bordered)
                            Button("试听万剑归宗") { state.previewSwordsReturnSound() }
                                .buttonStyle(.bordered)
                            Spacer()
                        }

                        Divider().overlay(palette.line)

                        Toggle("轻动效", isOn: $state.motionEnabled).toggleStyle(.switch)
                        Toggle("系统通知", isOn: $state.systemNotificationsEnabled).toggleStyle(.switch)
                        Toggle("23:00–08:00 夜间静默", isOn: $state.quietHoursEnabled).toggleStyle(.switch)

                        if state.systemNotificationsEnabled {
                            HStack {
                                Text(state.notificationStatusText)
                                    .foregroundStyle(state.notificationUnavailable ? palette.running : palette.tertiaryText)
                                Spacer()
                                Button("测试系统通知") { state.sendTestNotification() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                settingsCard(state.text("预览", "Preview")) {
                    VStack(spacing: 14) {
                        HStack(spacing: 12) {
                            ZStack(alignment: .topTrailing) {
                                RuntimeLogo(assetName: "codex.png", size: 34, appearance: state.appearance)
                                ZStack {
                                    Circle().fill(palette.unread).frame(width: 7, height: 7)
                                    Circle().stroke(palette.unread.opacity(0.28), lineWidth: 1)
                                        .frame(width: 17, height: 17)
                                        .scaleEffect(previewPulse ? 1.6 : 0.7)
                                        .opacity(previewPulse ? 0 : 1)
                                }
                                .offset(x: 4, y: -4)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(state.text("把剑令正式应用做出来", "Ship the Bladecall app"))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(palette.text)
                                Text(state.text("刚刚 · 复命未阅", "Just now · Ready"))
                                    .foregroundStyle(palette.unread)
                            }
                            Spacer()
                            Text(state.text("阅", "Open"))
                                .font(.custom("STKaiti", size: 20).weight(.semibold))
                                .foregroundStyle(palette.unread)
                                .frame(width: 31, height: 31)
                                .overlay(RoundedRectangle(cornerRadius: palette.cornerSmall).stroke(palette.unread.opacity(0.7)))
                        }
                        .jianlingFont(state.appearance, size: 11)
                        .padding(14)
                        .background(palette.unread.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: palette.cornerMedium).stroke(palette.line))
                        .clipShape(RoundedRectangle(cornerRadius: palette.cornerMedium))

                        HStack {
                            Text("默认不弹窗，也不催你。")
                                .foregroundStyle(palette.tertiaryText)
                            Spacer()
                            Button(state.text("预览复命", "Preview a return")) {
                                previewPulse = false
                                withAnimation(.easeOut(duration: 1.1).repeatCount(3, autoreverses: false)) {
                                    previewPulse = true
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(palette.accent)
                        }
                    }
                }

                settingsCard(state.text("剑迹日报", "Daily activity")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("隐藏幕后任务", isOn: $state.hideBackgroundInReports)
                            .toggleStyle(.switch)
                            .fontWeight(.semibold)
                        Text("开启后，日报会略去子 Agent、Multica 和宿主里看不到的技术过程；定时任务的复命仍会保留。")
                            .foregroundStyle(palette.secondaryText)
                        Text("App 前台时间仍会保留。")
                            .foregroundStyle(palette.tertiaryText)
                        Text(state.text(
                            "每天会同时生成中文和英文可视化日报；“剑迹”会打开当前界面语言的版本。",
                            "Bladecall generates both Chinese and English visual reports each day and opens the one matching your interface language."
                        ))
                            .foregroundStyle(palette.tertiaryText)
                    }
                }
            }
            .jianlingFont(state.appearance, size: 11)
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .jianlingFont(state.appearance, size: 10, weight: .semibold)
                .foregroundStyle(palette.secondaryText)
            content()
        }
        .padding(18)
        .background(palette.raised)
        .overlay(RoundedRectangle(cornerRadius: palette.cornerMedium).stroke(palette.line, lineWidth: state.appearance == .pixel ? 2 : 0.6))
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerMedium))
    }
}

private struct PresentationModeTile: View {
    let title: String
    let detail: String
    let symbol: String
    let selected: Bool
    let enabled: Bool
    let appearance: JianlingAppearance
    let action: () -> Void

    private var palette: JianlingPalette { JianlingPalette(appearance) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? palette.accent : palette.secondaryText)
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent) }
                }
                Text(title).fontWeight(.semibold).foregroundStyle(palette.text)
                Text(detail)
                    .jianlingFont(appearance, size: 8.5)
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            .background(selected ? palette.accent.opacity(0.075) : palette.row)
            .overlay {
                RoundedRectangle(cornerRadius: palette.cornerMedium)
                    .stroke(selected ? palette.accent.opacity(0.7) : palette.line, lineWidth: appearance == .pixel ? 2 : 0.8)
            }
            .clipShape(RoundedRectangle(cornerRadius: palette.cornerMedium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.48)
    }
}

private struct EnergySettingsPage: View {
    @ObservedObject var state: AppState
    private var palette: JianlingPalette { JianlingPalette(state.appearance) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    PageHeading(
                        title: state.text("剑气", "Energy"),
                        subtitle: state.text("扫一眼还剩多少余量，不让它抢走任务列表的位置。", "See what is left at a glance without crowding your task inbox."),
                        appearance: state.appearance
                    )
                    Spacer()
                    Button {
                        state.refreshQuota()
                    } label: {
                        HStack(spacing: 6) {
                            if state.quotaRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(state.text("刷新", "Refresh"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.quotaRefreshing)
                }

                card {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(state.text("在剑令上方显示剑气", "Show Energy above the inbox"))
                                .fontWeight(.semibold)
                                .foregroundStyle(palette.text)
                            Text(state.text("只占一条细栏；没有可用数据时自动隐藏。", "It uses one slim row and hides itself when no quota is available."))
                                .foregroundStyle(palette.tertiaryText)
                        }
                        Spacer()
                        Toggle("", isOn: $state.energyEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(state.text("选择要看的剑气", "Choose what to show"))
                        .jianlingFont(state.appearance, size: 10, weight: .semibold)
                        .foregroundStyle(palette.secondaryText)

                    ForEach(QuotaProvider.allCases) { provider in
                        providerCard(provider)
                    }
                }
                .opacity(state.energyEnabled ? 1 : 0.48)
                .disabled(!state.energyEnabled)

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(palette.handled)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.text("只读取额度状态", "Quota status only"))
                            .fontWeight(.semibold)
                            .foregroundStyle(palette.secondaryText)
                        Text(state.text(
                            "剑令沿用你在 Codex 和 Claude Code 的本机登录，只读取余量和恢复时间，不读取对话正文。",
                            "Bladecall uses your existing local Codex and Claude Code sign-ins to read remaining quota and reset times, never message content."
                        ))
                            .foregroundStyle(palette.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .jianlingFont(state.appearance, size: 10)

                if let date = state.quotaLastUpdated {
                    Text(state.text("上次更新：\(formatted(date))", "Last updated: \(formatted(date))"))
                        .jianlingFont(state.appearance, size: 9)
                        .foregroundStyle(palette.tertiaryText)
                }
            }
            .jianlingFont(state.appearance, size: 11)
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func providerCard(_ provider: QuotaProvider) -> some View {
        let snapshot = state.quotaSnapshot(for: provider)
        return VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                RuntimeLogo(
                    assetName: provider == .codex ? "codex.png" : "claude.png",
                    size: 30,
                    appearance: state.appearance
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.displayName)
                        .fontWeight(.semibold)
                        .foregroundStyle(palette.text)
                    Text(providerStatus(snapshot))
                        .jianlingFont(state.appearance, size: 9)
                        .foregroundStyle(statusColor(snapshot))
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { state.isQuotaProviderEnabled(provider) },
                    set: { state.setQuotaProvider(provider, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            if let windows = snapshot?.windows, !windows.isEmpty {
                Divider().overlay(palette.line.opacity(0.75))
                VStack(spacing: 12) {
                    ForEach(windows) { window in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 7) {
                                    Text(state.language.usesEnglish ? window.labelEnglish : window.labelChinese)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(palette.secondaryText)
                                    Text("\(Int(window.remainingPercent.rounded()))%")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(energyColor(window))
                                    if let resetAt = window.resetAt {
                                        Text(resetText(resetAt))
                                            .foregroundStyle(palette.tertiaryText)
                                    }
                                }
                                SettingsEnergyMeter(percent: window.remainingPercent, color: energyColor(window), appearance: state.appearance)
                                    .frame(maxWidth: 260)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { state.isQuotaWindowEnabled(window) },
                                set: { state.setQuotaWindow(window, enabled: $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }
                }
                .opacity(state.isQuotaProviderEnabled(provider) ? 1 : 0.45)
                .disabled(!state.isQuotaProviderEnabled(provider))
            }
        }
        .padding(16)
        .background(palette.raised)
        .overlay {
            RoundedRectangle(cornerRadius: palette.cornerMedium)
                .stroke(palette.line.opacity(0.68), lineWidth: state.appearance == .pixel ? 1 : 0.45)
        }
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerMedium))
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(palette.raised)
            .overlay {
                RoundedRectangle(cornerRadius: palette.cornerMedium)
                    .stroke(palette.line.opacity(0.62), lineWidth: state.appearance == .pixel ? 1 : 0.45)
            }
            .clipShape(RoundedRectangle(cornerRadius: palette.cornerMedium))
    }

    private func providerStatus(_ snapshot: QuotaProviderSnapshot?) -> String {
        guard let snapshot else { return state.text("正在读取", "Checking") }
        if snapshot.availability == .ready {
            return state.text("已读取 \(snapshot.windows.count) 项", "\(snapshot.windows.count) available")
        }
        return state.language.usesEnglish
            ? (snapshot.messageEnglish ?? "Unavailable")
            : (snapshot.messageChinese ?? "暂时不可用")
    }

    private func statusColor(_ snapshot: QuotaProviderSnapshot?) -> Color {
        guard let snapshot else { return palette.tertiaryText }
        switch snapshot.availability {
        case .ready: return palette.handled
        case .signedOut: return palette.running
        case .unavailable, .failed: return palette.tertiaryText
        }
    }

    private func energyColor(_ window: QuotaWindowSnapshot) -> Color {
        if window.remainingPercent <= 15 { return palette.seal }
        if window.remainingPercent <= 30 { return palette.running }
        return window.provider == .codex ? Color(rgb: 0x4E55F3) : Color(rgb: 0xD9704E)
    }

    private func resetText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = state.language.locale
        formatter.dateFormat = state.language.usesEnglish ? "MMM d, HH:mm" : "M月d日 HH:mm"
        return state.text("\(formatter.string(from: date)) 恢复", "resets \(formatter.string(from: date))")
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = state.language.locale
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

private struct SettingsEnergyMeter: View {
    let percent: Double
    let color: Color
    let appearance: JianlingAppearance

    var body: some View {
        GeometryReader { proxy in
            let count = max(10, Int(proxy.size.width / 14))
            let spacing: CGFloat = 2
            let width = max(2, (proxy.size.width - CGFloat(count - 1) * spacing) / CGFloat(count))
            HStack(spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    Rectangle()
                        .fill(index < filled(count) ? color : color.opacity(0.12))
                        .frame(width: width, height: 7)
                        .clipShape(RoundedRectangle(cornerRadius: appearance == .pixel ? 0 : 1.5))
                }
            }
        }
        .frame(height: 7)
    }

    private func filled(_ count: Int) -> Int {
        guard percent > 0 else { return 0 }
        return min(count, max(1, Int((percent / 100 * Double(count)).rounded())))
    }
}

private struct RuntimeSettingsPage: View {
    @ObservedObject var state: AppState
    @State private var filter: RuntimeCatalogFilter = .all
    @State private var selectedID: String = "codex"

    private var palette: JianlingPalette { JianlingPalette(state.appearance) }
    private var values: [RuntimeDescriptor] { RuntimeCatalog.values(for: filter) }
    private var selected: RuntimeDescriptor {
        RuntimeCatalog.all.first { $0.id == selectedID } ?? RuntimeCatalog.all[0]
    }
    private var guardedCount: Int { RuntimeCatalog.all.filter { $0.support == .guarded }.count }
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                PageHeading(
                    title: state.text("运行环境", "AI tools"),
                    subtitle: state.text("你在哪个工具里发任务，做完都回到这里。", "Work can start in different AI tools and return to one calm inbox."),
                    appearance: state.appearance
                )
                Spacer()
                Text(state.text("\(guardedCount) 个正在守护", "\(guardedCount) monitored"))
                    .jianlingFont(state.appearance, size: 10, weight: .semibold)
                    .foregroundStyle(palette.handled)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(palette.handled.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: palette.cornerSmall))
            }

            Picker("范围", selection: $filter) {
                ForEach(RuntimeCatalogFilter.allCases) { value in
                    Text("\(value.label(language: state.language)) \(RuntimeCatalog.values(for: value).count)").tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 360)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(values) { runtime in
                        RuntimeTile(
                            runtime: runtime,
                            selected: runtime.id == selectedID,
                            appearance: state.appearance,
                            language: state.language
                        ) {
                            selectedID = runtime.id
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            RuntimeDetail(runtime: selected, appearance: state.appearance, language: state.language)
        }
        .padding(32)
        .frame(maxWidth: 780, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct RuntimeTile: View {
    let runtime: RuntimeDescriptor
    let selected: Bool
    let appearance: JianlingAppearance
    let language: JianlingLanguage
    let action: () -> Void

    private var palette: JianlingPalette { JianlingPalette(appearance) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                RuntimeLogo(assetName: runtime.assetName, size: 29, appearance: appearance)
                VStack(alignment: .leading, spacing: 3) {
                    Text(runtime.name)
                        .fontWeight(.semibold)
                        .foregroundStyle(palette.text)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(runtime.statusLabel(language: language))
                            .foregroundStyle(statusColor)
                    }
                    .jianlingFont(appearance, size: 9)
                }
                Spacer()
            }
            .jianlingFont(appearance, size: 11)
            .padding(.horizontal, 13)
            .frame(height: 58)
            .background(selected ? palette.accent.opacity(0.075) : palette.raised)
            .overlay {
                RoundedRectangle(cornerRadius: palette.cornerMedium)
                    .stroke(selected ? palette.accent.opacity(0.65) : palette.line, lineWidth: appearance == .pixel ? 2 : 0.8)
            }
            .clipShape(RoundedRectangle(cornerRadius: palette.cornerMedium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch runtime.support {
        case .guarded: return palette.handled
        case .found: return runtime.foundOnMac ? palette.unread : palette.tertiaryText
        case .available: return runtime.foundOnMac ? palette.unread : palette.tertiaryText
        case .verifying: return palette.running
        }
    }
}

private struct RuntimeDetail: View {
    let runtime: RuntimeDescriptor
    let appearance: JianlingAppearance
    let language: JianlingLanguage

    private var palette: JianlingPalette { JianlingPalette(appearance) }

    var body: some View {
        HStack(spacing: 14) {
            RuntimeLogo(assetName: runtime.assetName, size: 34, appearance: appearance)
            VStack(alignment: .leading, spacing: 4) {
                Text(runtime.name)
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.text)
                Text(runtime.localizedDetail(language: language))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(2)
            }
            Spacer()
            Text(runtime.localizedAction(language: language))
                .fontWeight(.semibold)
                .foregroundStyle(runtime.support == .guarded ? palette.handled : palette.secondaryText)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(palette.row)
                .overlay(RoundedRectangle(cornerRadius: palette.cornerSmall).stroke(palette.line))
                .clipShape(RoundedRectangle(cornerRadius: palette.cornerSmall))
        }
        .jianlingFont(appearance, size: 10)
        .padding(14)
        .background(palette.raised)
        .overlay(RoundedRectangle(cornerRadius: palette.cornerMedium).stroke(palette.line))
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerMedium))
    }
}

private struct DeviceSettingsPage: View {
    @ObservedObject var state: AppState
    private var palette: JianlingPalette { JianlingPalette(state.appearance) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(
                    title: state.text("iPhone 与 Widget", "iPhone & Widget"),
                    subtitle: state.text("让手机看见剑令，也能把处理完的任务归鞘。", "Review AI work on your phone and mark finished items done."),
                    appearance: state.appearance
                )

                card(title: state.text("同一 Wi-Fi 配对", "Pair on the same Wi-Fi")) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .center, spacing: 22) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("在 iPhone 输入这 6 位码")
                                    .fontWeight(.semibold)
                                Text("配对码会在每次启动剑令时更新。")
                                    .foregroundStyle(palette.tertiaryText)
                            }
                            Spacer()
                            Text(formattedCode)
                                .font(.system(size: 29, weight: .bold, design: .monospaced))
                                .tracking(5)
                                .foregroundStyle(palette.text)
                            Button("复制") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(state.pairingCodeText, forType: .string)
                            }
                            .buttonStyle(.bordered)
                        }

                        Divider().overlay(palette.line)

                        HStack(spacing: 8) {
                            Circle().fill(connectionColor).frame(width: 8, height: 8)
                            Text(state.phoneConnectionStatus)
                                .fontWeight(.semibold)
                                .foregroundStyle(connectionColor)
                            Spacer()
                            Text("只在局域网内可见")
                                .foregroundStyle(palette.tertiaryText)
                        }
                    }
                }

                card(title: state.text("怎么连接", "How to connect")) {
                    HStack(alignment: .top, spacing: 10) {
                        instruction(
                            number: state.text("一", "1"),
                            title: state.text("同一网络", "Same network"),
                            detail: state.text("Mac 和 iPhone 连到同一个 Wi-Fi", "Connect your Mac and iPhone to the same Wi-Fi")
                        )
                        instruction(
                            number: state.text("二", "2"),
                            title: state.text("输入配对码", "Enter the code"),
                            detail: state.text("手机自动寻找这台 Mac", "Your phone will find this Mac")
                        )
                        instruction(
                            number: state.text("三", "3"),
                            title: state.text("开始收剑", "Start syncing"),
                            detail: state.text("状态实时同步，操作回到 Mac 执行", "Task state syncs live and actions run on the Mac")
                        )
                    }
                }

                card(title: state.text("离开同一网络", "Away from the same network")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("私人 iCloud 接力")
                                    .fontWeight(.semibold)
                                Text("开启后，手机不在同一 Wi-Fi 也能收取最新状态和送回“归”。")
                                    .foregroundStyle(palette.tertiaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("私人 iCloud", isOn: $state.iCloudSyncEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        HStack(spacing: 8) {
                            Circle()
                                .fill(state.iCloudSyncEnabled ? palette.unread : palette.tertiaryText)
                                .frame(width: 8, height: 8)
                            Text(state.iCloudSyncStatus)
                                .fontWeight(.semibold)
                                .foregroundStyle(state.iCloudSyncEnabled ? palette.secondaryText : palette.tertiaryText)
                        }
                        Text("关闭时，剑令不会把状态写入 iCloud；开启时也只进入你自己的私有数据库。")
                            .foregroundStyle(palette.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                card(title: state.text("数据边界", "Privacy")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("只同步标题、状态、时间和来源", systemImage: "checkmark.shield")
                            .fontWeight(.semibold)
                            .foregroundStyle(palette.handled)
                        Text("消息正文不会进入手机同步数据。定时任务会列在“例行剑令”；技术过程是否显示，继续沿用剑迹日报里的隐藏设置。")
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("同网直连默认开启；私人 iCloud 由你手动选择，两者都不传消息正文。")
                            .foregroundStyle(palette.tertiaryText)
                    }
                }
            }
            .jianlingFont(state.appearance, size: 11)
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var formattedCode: String {
        guard state.pairingCodeText.count == 6 else { return state.pairingCodeText }
        let split = state.pairingCodeText.index(state.pairingCodeText.startIndex, offsetBy: 3)
        return "\(state.pairingCodeText[..<split]) \(state.pairingCodeText[split...])"
    }

    private var connectionColor: Color {
        if state.phoneConnectionStatus.contains("已连接")
            || state.phoneConnectionStatus.localizedCaseInsensitiveContains("connected") {
            return palette.handled
        }
        if state.phoneConnectionStatus.contains("异常")
            || state.phoneConnectionStatus.localizedCaseInsensitiveContains("issue") {
            return palette.running
        }
        return palette.unread
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .jianlingFont(state.appearance, size: 10, weight: .semibold)
                .foregroundStyle(palette.secondaryText)
            content()
        }
        .padding(18)
        .background(palette.raised)
        .overlay(RoundedRectangle(cornerRadius: palette.cornerMedium).stroke(palette.line))
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerMedium))
    }

    private func instruction(number: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(number)
                .font(.custom("STKaiti", size: 18).weight(.semibold))
                .foregroundStyle(palette.seal)
            Text(title).fontWeight(.semibold).foregroundStyle(palette.text)
            Text(detail).foregroundStyle(palette.tertiaryText).fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.row)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerSmall))
    }
}

private struct ProfileSettingsPage: View {
    @ObservedObject var state: AppState
    private var palette: JianlingPalette { JianlingPalette(state.appearance) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(
                title: state.text("个人资料", "Profile"),
                subtitle: state.text("用于日报署名；其他资料以后再补也可以。", "Used to sign daily reports. You can fill in the rest later."),
                appearance: state.appearance
            )

            VStack(alignment: .leading, spacing: 17) {
                field(state.text("你的称呼", "Your name"), text: $state.displayName, placeholder: state.text("剑客", "Commander"))
                field(state.text("组织或项目", "Organization or project"), text: $state.organization, placeholder: state.text("稍后补充", "Add later"))
                field(state.text("日报署名", "Report signature"), text: $state.reportSignature, placeholder: state.text("可留空", "Optional"))
            }
            .padding(20)
            .background(palette.raised)
            .overlay(RoundedRectangle(cornerRadius: palette.cornerMedium).stroke(palette.line))
            .clipShape(RoundedRectangle(cornerRadius: palette.cornerMedium))

            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text("这些资料只留在本机，随时都能改。")
            }
            .jianlingFont(state.appearance, size: 10)
            .foregroundStyle(palette.tertiaryText)
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .jianlingFont(state.appearance, size: 10, weight: .semibold)
                .foregroundStyle(palette.secondaryText)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .jianlingFont(state.appearance, size: 12)
        }
    }
}

private struct AboutSettingsPage: View {
    @ObservedObject var state: AppState
    private var palette: JianlingPalette { JianlingPalette(state.appearance) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 20) {
                    Text(state.text("令", "B"))
                        .font(.custom("STKaiti", size: 46).weight(.semibold))
                        .foregroundStyle(Color(rgb: 0xFFF3D9))
                        .frame(width: 74, height: 74)
                        .background(palette.seal)
                        .rotationEffect(.degrees(-2))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(state.text("人掌令，AI 行剑", "You stay in command"))
                            .font(.custom("STKaiti", size: 30).weight(.semibold))
                            .foregroundStyle(palette.text)
                        Text("\(state.language.productName) · \(versionText)")
                            .jianlingFont(state.appearance, size: 10)
                            .foregroundStyle(palette.tertiaryText)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(state.text(
                        "AI 应该扩张人的行动力，\n而不是收割人的注意力。",
                        "AI should expand what you can do—\nnot compete for your attention."
                    ))
                        .font(.custom("STKaiti", size: 23).weight(.medium))
                        .foregroundStyle(palette.text)
                        .lineSpacing(5)
                    Text(state.text(
                        "你把任务发出去，AI 各自去做；做完后回到这个安静的收件箱。什么时候看、什么时候归鞘，都由你决定。",
                        "Send work to multiple AI tools and let the results return to one calm inbox. You decide when to review them and when they are done."
                    ))
                        .jianlingFont(state.appearance, size: 11)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.raised)
                .overlay(alignment: .leading) { Rectangle().fill(palette.seal).frame(width: 3) }

                HStack(spacing: 8) {
                    LoopStep(number: state.text("一", "1"), title: state.text("发令", "Dispatch"), detail: state.text("任务出发", "Send the work"), appearance: state.appearance)
                    Image(systemName: "arrow.right").foregroundStyle(palette.tertiaryText)
                    LoopStep(number: state.text("二", "2"), title: state.text("行剑", "Run"), detail: state.text("AI 行动", "AI does the work"), appearance: state.appearance)
                    Image(systemName: "arrow.right").foregroundStyle(palette.tertiaryText)
                    LoopStep(number: state.text("三", "3"), title: state.text("复命", "Return"), detail: state.text("结果回令", "Results come back"), appearance: state.appearance)
                    Image(systemName: "arrow.right").foregroundStyle(palette.tertiaryText)
                    LoopStep(number: state.text("四", "4"), title: state.text("归鞘", "Done"), detail: state.text("由你收束", "You close the loop"), appearance: state.appearance)
                }

                HStack(spacing: 10) {
                    Principle(title: state.text("数据留在本机", "Local by default"), detail: state.text("状态和剑迹不上传", "Activity stays on your devices"), appearance: state.appearance)
                    Principle(title: state.text("安静复命", "Quiet by design"), detail: state.text("默认不弹窗、不催你", "No pop-ups or pressure by default"), appearance: state.appearance)
                    Principle(title: state.text("人来收束", "Human in command"), detail: state.text("你决定阅与归", "You decide when work is done"), appearance: state.appearance)
                }

                Spacer(minLength: 10)

                Text("为并行使用 AI 的人而做")
                    .jianlingFont(state.appearance, size: 9)
                    .foregroundStyle(palette.tertiaryText)
            }
            .padding(36)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3"
    }
}

private struct PageHeading: View {
    let title: String
    let subtitle: String
    let appearance: JianlingAppearance

    private var palette: JianlingPalette { JianlingPalette(appearance) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .jianlingFont(appearance, size: 23, weight: .bold)
                .foregroundStyle(palette.text)
            Text(subtitle)
                .jianlingFont(appearance, size: 11)
                .foregroundStyle(palette.secondaryText)
        }
    }
}

private struct LoopStep: View {
    let number: String
    let title: String
    let detail: String
    let appearance: JianlingAppearance

    private var palette: JianlingPalette { JianlingPalette(appearance) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(number)
                .font(.custom("STKaiti", size: 17).weight(.semibold))
                .foregroundStyle(palette.seal)
            Text(title).fontWeight(.semibold).foregroundStyle(palette.text)
            Text(detail).foregroundStyle(palette.tertiaryText)
        }
        .jianlingFont(appearance, size: 9)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.raised)
        .overlay(RoundedRectangle(cornerRadius: palette.cornerSmall).stroke(palette.line))
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerSmall))
    }
}

private struct Principle: View {
    let title: String
    let detail: String
    let appearance: JianlingAppearance

    private var palette: JianlingPalette { JianlingPalette(appearance) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).fontWeight(.semibold).foregroundStyle(palette.text)
            Text(detail).foregroundStyle(palette.tertiaryText)
        }
        .jianlingFont(appearance, size: 9)
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.row)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerSmall))
    }
}
