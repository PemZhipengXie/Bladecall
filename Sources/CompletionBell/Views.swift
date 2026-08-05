import AppKit
import CompletionBellCore
import JianlingShared
import SwiftUI

private struct InboxContainerShape: InsettableShape {
    let surface: InboxSurface
    let cornerRadius: CGFloat
    private var insetAmount: CGFloat = 0

    init(surface: InboxSurface, cornerRadius: CGFloat, insetAmount: CGFloat = 0) {
        self.surface = surface
        self.cornerRadius = cornerRadius
        self.insetAmount = insetAmount
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        guard surface == .edgeExpanded || surface == .notchExpanded, radius > 0 else {
            return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
        }
        var path = Path()
        if surface == .notchExpanded {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + radius), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> InboxContainerShape {
        InboxContainerShape(surface: surface, cornerRadius: max(0, cornerRadius - amount), insetAmount: insetAmount + amount)
    }
}

private struct InboxContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PopoverView: View {
    @ObservedObject var state: AppState
    let surface: InboxSurface
    let onClose: () -> Void
    var onTogglePin: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var inboxContentHeight: CGFloat = 0
    @State private var inboxViewportHeight: CGFloat = 0

    private var palette: JianlingPalette { JianlingPalette(state.appearance, colorScheme: colorScheme) }
    private var chrome: SurfaceChromePolicy { SurfaceChromePolicy(surface: surface) }
    private var isCompactSurface: Bool { surface == .edgeExpanded || surface == .notchExpanded }
    private var compactPinned: Bool { surface == .notchExpanded ? state.notchPinned : state.edgePinned }
    private var motionEnabled: Bool { state.motionEnabled && !reduceMotion }
    private var mainUnreadCount: Int {
        state.inboxSessions.filter { state.attentionState(for: $0) == .unread }.count
    }
    private var measuredInboxItemCount: Int {
        state.inboxSessions.count
            + ((isCompactSurface && !state.isExpanded("routine")) ? 0 : state.routineSessions.count)
            + (state.isExpanded("background") ? state.backgroundSessions.count : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            if chrome.showsHeader { header }
            if chrome.showsSummary { summary }
            if chrome.showsEnergy && !state.visibleQuotaProviders.isEmpty {
                EnergyBelt(state: state)
            }
            inbox
            if chrome.showsFooter { footer }
        }
        .frame(
            minWidth: CGFloat(surface == .menu ? PresentationLayout.menuWidth : PresentationLayout.floatingMinimumWidth),
            maxWidth: .infinity,
            minHeight: CGFloat(surface == .menu ? PresentationLayout.menuHeight : PresentationLayout.floatingMinimumHeight),
            maxHeight: .infinity
        )
        .background { containerBackground }
        .clipShape(containerShape)
        .overlay { containerBorder }
        .jianlingFontScale(state.fontScale)
        .environment(\.locale, state.language.locale)
    }

    /// The floating modern container is a translucent material card: blur
    /// with a surface tint so content stays legible, continuous rounded
    /// corners, and a light top edge so the glass catches light. The menu
    /// popover keeps square edges (NSPopover supplies its own chrome), and
    /// the pixel theme stays deliberately flat and hard-edged.
    private var isGlass: Bool {
        (surface == .floating || surface == .edgeExpanded) && state.appearance == .modern
    }

    @ViewBuilder
    private var containerBackground: some View {
        if surface == .notchExpanded {
            // The shell is the same pure black as the physical notch — that is
            // what lets the panel read as the notch flowing open rather than a
            // warm-tinted card parked on top of it. Rows keep the dark scheme.
            Color.black
        } else if isGlass {
            ZStack {
                if reduceTransparency {
                    palette.surface
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                    // The edge panel is a transient overlay on top of whatever
                    // the user is working in, so it reads lighter than the
                    // resident floating window.
                    palette.surface.opacity(surface == .edgeExpanded ? 0.42 : 0.62)
                }
            }
        } else {
            palette.surface
        }
    }

    private var containerShape: InboxContainerShape {
        InboxContainerShape(
            surface: surface,
            cornerRadius: surface == .notchExpanded
                ? NotchGeometryResolver.expandedBottomCornerRadius
                : (isGlass ? palette.cornerLarge : 0)
        )
    }

    @ViewBuilder
    private var containerBorder: some View {
        if surface == .notchExpanded {
            // No stroke: the notch has no outline, so neither does its extension.
            EmptyView()
        } else if isGlass {
            containerShape
                .strokeBorder(palette.line, lineWidth: 0.6)
                .overlay {
                    containerShape
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.5), .white.opacity(0.06)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.8
                        )
                        .blendMode(.plusLighter)
                }
        } else {
            Rectangle()
                .stroke(palette.line, lineWidth: state.appearance == .pixel ? 3 : 0.6)
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            JianlingSeal(size: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.language.productName)
                    .font(.custom("STKaiti", size: 23).weight(.semibold))
                    .foregroundStyle(state.appearance == .pixel ? Color(rgb: 0xFFF3D9) : palette.text)
                Text(state.text("\(state.totalVisibleCount) 枚在途", "\(state.totalVisibleCount) in flight"))
                    .jianlingFont(state.appearance, size: 10)
                    .foregroundStyle(state.appearance == .pixel ? Color(rgb: 0xD8C29B) : palette.tertiaryText)
            }
            Spacer()
            Group {
                if state.language.usesEnglish {
                    Image(systemName: state.noticeStyle == .quiet ? "bell.slash" : "speaker.wave.2")
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    Text(state.noticeStyle == .quiet ? "静" : "鸣")
                        .font(.custom("STSong", size: 11).weight(.semibold))
                }
            }
                .foregroundStyle(state.noticeStyle == .quiet ? palette.tertiaryText : palette.running)
                .frame(width: 25, height: 25)
                .background(palette.row)
                .overlay(RoundedRectangle(cornerRadius: palette.cornerSmall).stroke(palette.line))
                .clipShape(RoundedRectangle(cornerRadius: palette.cornerSmall))

            if isCompactSurface, let onTogglePin {
                Button(action: onTogglePin) {
                    Image(systemName: compactPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 27, height: 27)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(compactPinned ? palette.accent : palette.secondaryText)
                .background(palette.row)
                .clipShape(RoundedRectangle(cornerRadius: palette.cornerSmall))
                .help(state.text(compactPinned ? "取消固定展开" : "固定展开", compactPinned ? "Unpin" : "Keep expanded"))
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 27, height: 27)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.secondaryText)
            .background(palette.row)
            .clipShape(RoundedRectangle(cornerRadius: palette.cornerSmall))
            .help(state.text("关闭窗口，剑令继续在后台监控", "Close the window and keep monitoring"))
        }
        .padding(.horizontal, 17)
        .frame(height: 74)
        .background(state.appearance == .pixel ? Color(rgb: 0x211813) : palette.surface.opacity(surface == .menu ? 1 : 0.4))
        .foregroundStyle(state.appearance == .pixel ? Color(rgb: 0xFFF3D9) : palette.text)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    private var summary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text("\(state.activeCount)")
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.text)
                Text(state.text("行剑中", "in progress"))
                Text("·")
                Text("\(mainUnreadCount)")
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.text)
                Text(state.text("枚未读", "ready"))
                if !state.routineSessions.isEmpty {
                    Text("·")
                    Text(state.text("例行 \(state.routineSessions.count)", "routine \(state.routineSessions.count)"))
                        .foregroundStyle(palette.accent)
                }
                Spacer()
                if state.snoozedCount > 0 {
                    Text(state.text("已推 \(state.snoozedCount)", "snoozed \(state.snoozedCount)"))
                        .foregroundStyle(palette.tertiaryText)
                    Text("·")
                }
                Text(state.text("今日归鞘 \(state.todayHandledCount)", "done today \(state.todayHandledCount)"))
                    .foregroundStyle(palette.handled)
                    .fontWeight(.semibold)
            }
            HStack(spacing: 5) {
                Text(state.text(
                    "行剑 \(state.activeCount) · 未读 \(mainUnreadCount) · 例行 \(state.routineSessions.count)",
                    "active \(state.activeCount) · ready \(mainUnreadCount) · routine \(state.routineSessions.count)"
                ))
                Spacer()
                if state.snoozedCount > 0 {
                    Text(state.text("推 \(state.snoozedCount)", "zzz \(state.snoozedCount)"))
                        .foregroundStyle(palette.tertiaryText)
                }
                Text(state.text("归 \(state.todayHandledCount)", "done \(state.todayHandledCount)"))
                    .foregroundStyle(palette.handled)
                    .fontWeight(.semibold)
            }
        }
        .jianlingFont(state.appearance, size: 10)
        .foregroundStyle(palette.secondaryText)
        .padding(.horizontal, 17)
        .frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    private var inbox: some View {
        GeometryReader { viewport in
            ScrollView {
            LazyVStack(spacing: 0) {
                if state.inboxSessions.isEmpty && state.routineSessions.isEmpty {
                    EmptyInbox(appearance: state.appearance, language: state.language)
                        .padding(.vertical, 26)
                } else if !state.inboxSessions.isEmpty {
                    ForEach(state.inboxSessions) { session in
                        SessionRow(state: state, session: session, context: .interactive, surface: surface)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .trailing)))
                        Divider().overlay(palette.line).padding(.leading, 54)
                    }
                }

                if !state.routineSessions.isEmpty {
                    routineHeader
                    if !isCompactSurface || state.isExpanded("routine") {
                        ForEach(state.routineSessions) { session in
                            SessionRow(state: state, session: session, context: .routine, surface: surface)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            Divider().overlay(palette.line).padding(.leading, 54)
                        }
                    }
                }

                if !state.backgroundSessions.isEmpty {
                    backgroundHeader
                    if state.isExpanded("background") {
                        ForEach(state.backgroundSessions) { session in
                            SessionRow(state: state, session: session, context: .background, surface: surface)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            Divider().overlay(palette.line).padding(.leading, 54)
                        }
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.top, 4)
            .animation(motionEnabled ? .easeOut(duration: 0.18) : nil, value: state.inboxSessions.map(\.id))
            .animation(motionEnabled ? .easeOut(duration: 0.18) : nil, value: state.routineSessions.map(\.id))
            .animation(motionEnabled ? .easeOut(duration: 0.18) : nil, value: state.backgroundSessions.map(\.id))
                .background {
                    GeometryReader { content in
                        Color.clear.preference(key: InboxContentHeightKey.self, value: content.size.height)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .onAppear { inboxViewportHeight = viewport.size.height }
            .onChange(of: viewport.size.height) { inboxViewportHeight = $0 }
            .onPreferenceChange(InboxContentHeightKey.self) { inboxContentHeight = $0 }
            .overlay(alignment: .bottomTrailing) {
                if isCompactSurface,
                   inboxViewportHeight > 0,
                   inboxContentHeight > inboxViewportHeight + 1,
                   measuredInboxItemCount > 0 {
                    let averageRowHeight = max(1, inboxContentHeight / CGFloat(measuredInboxItemCount))
                    let remaining = min(measuredInboxItemCount, max(1, Int(ceil((inboxContentHeight - inboxViewportHeight) / averageRowHeight))))
                    Text(state.text("还有 \(remaining) 条", "\(remaining) more"))
                        .jianlingFont(state.appearance, size: 8.5, weight: .semibold)
                        .foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(palette.raised.opacity(0.94))
                        .clipShape(Capsule())
                        .padding(9)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var routineHeader: some View {
        HStack(spacing: 0) {
            if isCompactSurface {
                Button {
                    let expanded = !state.isExpanded("routine")
                    if motionEnabled {
                        withAnimation(.easeOut(duration: 0.18)) { state.setExpanded(expanded, groupID: "routine") }
                    } else {
                        state.setExpanded(expanded, groupID: "routine")
                    }
                } label: { routineHeaderLabel }
                .buttonStyle(.plain)
            } else {
                routineHeaderLabel
            }
            if routineSheatheTargets > 0 {
                groupSheatheSeal(sessions: state.routineSessions, groupID: "routine")
                    .padding(.trailing, 8)
            }
        }
        .jianlingFont(state.appearance, size: 10)
        .background(palette.accent.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerSmall))
        .padding(.vertical, 5)
    }

    private var routineHeaderLabel: some View {
        HStack(spacing: 8) {
            if isCompactSurface {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(state.isExpanded("routine") ? 90 : 0))
            } else {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(state.text("例行剑令", "Routine runs"))
                .fontWeight(.semibold)
            Spacer()
            if state.routineUnreadCount > 0 {
                Text(state.text("\(state.routineUnreadCount) 枚未阅", "\(state.routineUnreadCount) ready"))
                    .foregroundStyle(palette.unread)
            } else if state.routineRunningCount > 0 {
                Text(state.text("\(state.routineRunningCount) 枚执行中", "\(state.routineRunningCount) running"))
                    .foregroundStyle(palette.running)
            } else {
                Text("\(state.routineSessions.count)")
                    .foregroundStyle(palette.tertiaryText)
            }
        }
        .foregroundStyle(palette.secondaryText)
        .padding(.leading, 10)
        .padding(.trailing, routineSheatheTargets > 0 ? 8 : 10)
        .frame(height: 35)
        .contentShape(Rectangle())
    }

    private var routineSheatheTargets: Int {
        state.routineSessions.filter { state.attentionState(for: $0).needsUserAttention }.count
    }

    private var backgroundSheatheTargets: Int { state.backgroundCounts.pending }

    /// 「万剑归宗」— one seal sheathes every finished session in the group.
    private func groupSheatheSeal(sessions: [SessionSnapshot], groupID: String) -> some View {
        SealButton(
            character: "宗",
            color: palette.seal,
            appearance: state.appearance,
            motionEnabled: motionEnabled,
            width: 24,
            height: 24,
            fontSize: 14
        ) {
            if motionEnabled {
                withAnimation(.easeOut(duration: 0.18)) { state.sheatheAll(sessions, groupID: groupID) }
            } else {
                state.sheatheAll(sessions, groupID: groupID)
            }
        }
        .help(state.text("万剑归宗：全组归鞘，行剑中的跳过", "Sheathe every finished run in this group"))
    }

    private var backgroundHeader: some View {
        // The sheathe seal must sit OUTSIDE the fold button — a Button nested
        // in another Button's label fires both.
        HStack(spacing: 0) {
            Button {
                if motionEnabled {
                    withAnimation(.easeOut(duration: 0.18)) {
                        state.setExpanded(!state.isExpanded("background"), groupID: "background")
                    }
                } else {
                    state.setExpanded(!state.isExpanded("background"), groupID: "background")
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(state.isExpanded("background") ? 90 : 0))
                        .animation(motionEnabled ? .easeOut(duration: 0.18) : nil, value: state.isExpanded("background"))
                        .foregroundStyle(palette.accent)
                    Text(state.text("幕后剑令", "Background runs"))
                        .fontWeight(.semibold)
                    Spacer()
                    if state.backgroundUnreadCount > 0 {
                        Text(state.text("\(state.backgroundUnreadCount) 枚待看", "\(state.backgroundUnreadCount) ready"))
                            .foregroundStyle(palette.unread)
                    } else {
                        Text("\(state.backgroundSessions.count)")
                            .foregroundStyle(palette.tertiaryText)
                    }
                }
                .jianlingFont(state.appearance, size: 10)
                .foregroundStyle(palette.secondaryText)
                .padding(.leading, 10)
                .padding(.trailing, backgroundSheatheTargets > 0 ? 8 : 10)
                .frame(height: 39)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if backgroundSheatheTargets > 0 {
                groupSheatheSeal(sessions: state.backgroundSessions, groupID: "background")
                    .padding(.trailing, 8)
            }
        }
        .background(palette.row)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerSmall))
        .padding(.vertical, 5)
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 15) {
                footerButtons
                Spacer()
                footerStatus
            }
            HStack(spacing: 12) {
                Button { state.openDailyReport() } label: {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                }
                Button { state.refreshSessions() } label: {
                    if state.sessionRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(state.sessionRefreshing)
                Button { state.onOpenSettings?() } label: {
                    Image(systemName: "gearshape")
                }
                Spacer()
                footerStatus
                }
        .frame(maxWidth: .infinity)
    }
        .jianlingFont(state.appearance, size: 10)
        .foregroundStyle(palette.secondaryText)
        .padding(.horizontal, 17)
        .frame(height: 45)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    private var footerButtons: some View {
        Group {
            Button { state.openDailyReport() } label: {
                Label("剑迹", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            Button { state.refreshSessions() } label: {
                if state.sessionRefreshing {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(state.text("刷新中", "Refreshing"))
                    }
                } else {
                    Label(state.text("刷新", "Refresh"), systemImage: "arrow.clockwise")
                }
            }
            .disabled(state.sessionRefreshing)
            Button { state.onOpenSettings?() } label: {
                Label("设置", systemImage: "gearshape")
            }
        }
    }

    private var footerStatus: some View {
        HStack(spacing: 6) {
            if state.sessionRefreshing {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(state.parseErrorCount > 10 ? palette.running : palette.handled)
                    .frame(width: 6, height: 6)
            }
            Text(state.monitorStatus)
                .foregroundStyle(state.sessionRefreshing
                    ? palette.accent
                    : (state.parseErrorCount > 10 ? palette.running : palette.handled))
                .lineLimit(1)
        }
    }
}

private struct EnergyBelt: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    private var palette: JianlingPalette { JianlingPalette(state.appearance, colorScheme: colorScheme) }

    var body: some View {
        HStack(spacing: 8) {
            Text(state.text("剑气", "Energy"))
                .jianlingFont(state.appearance, size: 8, weight: .semibold)
                .foregroundStyle(palette.tertiaryText)
                .fixedSize()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(state.visibleQuotaProviders) { provider in
                        providerMeter(provider)
                    }
                }
                .padding(.trailing, 2)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 37)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.line.opacity(0.42)).frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private func providerMeter(_ provider: QuotaProviderSnapshot) -> some View {
        HStack(spacing: 6) {
            RuntimeLogo(
                assetName: provider.provider == .codex ? "codex.png" : "claude.png",
                size: 16,
                appearance: state.appearance
            )
            .opacity(0.9)
            ForEach(Array(provider.windows.prefix(3).enumerated()), id: \.element.id) { index, window in
                if index > 0 {
                    Rectangle()
                        .fill(palette.line.opacity(0.42))
                        .frame(width: 0.5, height: 15)
                }
                windowMeter(window)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(providerHelp(provider))
        .accessibilityLabel(provider.provider.displayName)
    }

    private func windowMeter(_ window: QuotaWindowSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(state.language.usesEnglish ? window.labelEnglish : window.labelChinese)
                    .foregroundStyle(palette.tertiaryText)
                Text("\(Int(window.remainingPercent.rounded()))%")
                    .fontWeight(.semibold)
                    .foregroundStyle(meterColor(window))
            }
            .jianlingFont(state.appearance, size: 8)

            SegmentedEnergyMeter(
                percent: window.remainingPercent,
                color: meterColor(window),
                appearance: state.appearance
            )
        }
    }

    private func meterColor(_ window: QuotaWindowSnapshot) -> Color {
        if window.remainingPercent <= 15 { return palette.seal }
        if window.remainingPercent <= 30 { return palette.running }
        switch window.provider {
        case .codex: return Color(rgb: 0x4E55F3)
        case .claude: return Color(rgb: 0xD9704E)
        }
    }

    private func providerHelp(_ provider: QuotaProviderSnapshot) -> String {
        let values = provider.windows.map { window -> String in
            let label = state.language.usesEnglish ? window.labelEnglish : window.labelChinese
            var text = "\(label) \(Int(window.remainingPercent.rounded()))%"
            if let reset = window.resetAt {
                let formatter = DateFormatter()
                formatter.locale = state.language.locale
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                text += state.text(" · \(formatter.string(from: reset)) 恢复", " · resets \(formatter.string(from: reset))")
            }
            return text
        }
        return ([provider.provider.displayName] + values).joined(separator: "\n")
    }
}

private struct SegmentedEnergyMeter: View {
    let percent: Double
    let color: Color
    let appearance: JianlingAppearance

    private let segmentCount = 10

    var body: some View {
        HStack(spacing: 1.25) {
            ForEach(0..<segmentCount, id: \.self) { index in
                Rectangle()
                    .fill(index < filledSegments ? color : color.opacity(0.13))
                    .frame(width: 4.4, height: 4)
                    .clipShape(RoundedRectangle(cornerRadius: appearance == .pixel ? 0 : 1.1))
            }
        }
        .accessibilityValue("\(Int(percent.rounded())) percent")
    }

    private var filledSegments: Int {
        guard percent > 0 else { return 0 }
        return min(segmentCount, max(1, Int(ceil(percent / 100 * Double(segmentCount)))))
    }
}

private struct SessionRow: View {
    enum Context {
        case interactive
        case routine
        case background
    }

    @ObservedObject var state: AppState
    let session: SessionSnapshot
    let context: Context
    let surface: InboxSurface

    @Environment(\.colorScheme) private var colorScheme
    private var palette: JianlingPalette { JianlingPalette(state.appearance, colorScheme: colorScheme) }
    private var attention: AttentionState { state.attentionState(for: session) }
    private var stalled: Bool { state.isStalled(session) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var motionEnabled: Bool { state.motionEnabled && !reduceMotion }
    @State private var hovering = false
    @FocusState private var rowFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button { state.open(session) } label: {
                HStack(spacing: 10) {
                    ZStack(alignment: .topTrailing) {
                        RuntimeLogo(assetName: toolAsset(session), size: 30, appearance: state.appearance)
                        if attention == .unread {
                            UnreadPin(color: palette.unread, motionEnabled: state.motionEnabled)
                                .offset(x: 3, y: -3)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title)
                            .lineLimit(1)
                            .foregroundStyle(palette.text)
                            .jianlingFont(
                                state.appearance,
                                size: 11.5,
                                weight: attention == .unread ? .semibold : .medium
                            )
                        HStack(spacing: 4) {
                            if session.tool == .external {
                                // Honesty tier: this row is the agent's own
                                // claim, not a natively watched signal.
                                Text("\(session.toolDisplayName) · \(state.text("自报", "self-report"))")
                                Text("·")
                            }
                            Text(relative(session.lastActivity, language: state.language))
                            Text("·")
                            Circle().fill(statusColor).frame(width: 6, height: 6)
                            Text(statusText).foregroundStyle(statusColor)
                        }
                        .jianlingFont(state.appearance, size: 9)
                        .foregroundStyle(palette.tertiaryText)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SealPressButtonStyle(motionEnabled: motionEnabled, scale: 0.985))

            if attention.needsUserAttention {
                snoozeMenu
            }

            if attention == .unread {
                SealButton(
                    character: state.text("阅", "Open"),
                    color: palette.unread,
                    appearance: state.appearance,
                    motionEnabled: motionEnabled
                ) {
                    state.open(session)
                }
                .help("打开原 App 并标为已阅")
            } else if attention == .pending {
                SealButton(
                    character: state.text("归", "Done"),
                    color: palette.seal,
                    appearance: state.appearance,
                    motionEnabled: motionEnabled
                ) {
                    if motionEnabled {
                        withAnimation(.easeOut(duration: 0.18)) { state.markHandled(session) }
                    } else {
                        state.markHandled(session)
                    }
                }
                .help("已处理，归鞘并离开收件箱")
            }
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 55)
        .background(rowBackground)
        .overlay(alignment: .bottomTrailing) {
            if attention == .unread && motionEnabled {
                ReturnLine(color: palette.unread)
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)
                    .padding(.leading, 48)
                    .padding(.trailing, 40)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerSmall))
        .onHover { hovering = $0 }
        .focusable(surface == .edgeExpanded || surface == .notchExpanded)
        .focused($rowFocused)
        .accessibilityAction(named: state.text("打开剑令", "Open session")) {
            state.open(session)
        }
        .contextMenu {
            if attention.needsUserAttention {
                snoozeMenuItems
            }
        }
    }

    /// 「推」— hover-only so idle rows stay clean; the right-click menu is the
    /// always-available fallback when hover doesn't reach a non-active panel.
    private var snoozeMenu: some View {
        Menu {
            snoozeMenuItems
        } label: {
            Image(systemName: (surface == .edgeExpanded || surface == .notchExpanded) ? "ellipsis" : "hourglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.tertiaryText)
                .frame(width: 20, height: 29)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity((surface == .edgeExpanded || surface == .notchExpanded) ? 1 : (hovering ? 1 : 0))
        .allowsHitTesting(surface == .edgeExpanded || surface == .notchExpanded || hovering)
        .help(state.text("推：暂时挪开，到点自动回来", "Push away; it returns on time"))
    }

    @ViewBuilder private var snoozeMenuItems: some View {
        ForEach(SnoozeOption.visibleOptions(now: Date()), id: \.self) { option in
            Button(snoozeLabel(option)) {
                if motionEnabled {
                    withAnimation(.easeOut(duration: 0.18)) { state.snooze(session, option: option) }
                } else {
                    state.snooze(session, option: option)
                }
            }
        }
    }

    private func snoozeLabel(_ option: SnoozeOption) -> String {
        switch option {
        case .oneHour: return state.text("推 1 小时", "In 1 hour")
        case .threeHours: return state.text("推 3 小时", "In 3 hours")
        case .tonight: return state.text("今晚 20:00", "Tonight 8 PM")
        case .tomorrowMorning: return state.text("明早 9:00", "Tomorrow 9 AM")
        }
    }

    private var rowBackground: Color {
        switch attention {
        case .unread: return palette.unread.opacity(0.055)
        case .pending: return palette.pending.opacity(0.035)
        case .running, .handled: return Color.clear
        }
    }

    private var statusText: String {
        if stalled { return state.text("无新事件", "No new activity") }
        switch attention {
        case .running:
            switch context {
            case .interactive: return state.text("行剑中", "In progress")
            case .routine: return state.text("例行中", "Routine running")
            case .background: return state.text("幕后行剑", "Running in background")
            }
        case .unread:
            switch context {
            case .interactive: return state.text("复命未阅", "Ready")
            case .routine: return state.text("例行复命", "Routine ready")
            case .background: return state.text("复命待看", "Background result")
            }
        case .pending: return state.text("已阅待决", "Reviewed")
        case .handled: return state.text("已归鞘", "Done")
        }
    }

    private var statusColor: Color {
        if stalled { return palette.tertiaryText }
        switch attention {
        case .running: return palette.running
        case .unread: return palette.unread
        case .pending: return palette.pending
        case .handled: return palette.handled
        }
    }
}

private struct SealButton: View {
    let character: String
    let color: Color
    let appearance: JianlingAppearance
    let motionEnabled: Bool
    var width: CGFloat? = nil
    var height: CGFloat = 29
    var fontSize: CGFloat = 18
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(character)
                .font(character.count > 1
                    ? .system(size: 9, weight: .semibold)
                    : .custom("STKaiti", size: fontSize).weight(.semibold))
                .foregroundStyle(color)
                .frame(width: width ?? (character.count > 1 ? 42 : 29), height: height)
                .background(color.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: appearance == .pixel ? 0 : 5)
                        .stroke(color.opacity(0.72), lineWidth: 1.2)
                }
                .rotationEffect(.degrees(-2))
        }
        .buttonStyle(SealPressButtonStyle(motionEnabled: motionEnabled))
    }
}

private struct SealPressButtonStyle: ButtonStyle {
    let motionEnabled: Bool
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(motionEnabled && configuration.isPressed ? scale : 1)
            .animation(
                motionEnabled ? .easeOut(duration: 0.14) : nil,
                value: configuration.isPressed
            )
    }
}

private struct UnreadPin: View {
    let color: Color
    let motionEnabled: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(color).frame(width: 7, height: 7)
            Circle()
                .stroke(color.opacity(0.35), lineWidth: 1)
                .frame(width: 15, height: 15)
                .scaleEffect(pulse ? 1.45 : 0.55)
                .opacity(pulse ? 0 : 1)
        }
        .frame(width: 15, height: 15)
        .onAppear {
            guard motionEnabled && !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.15).repeatCount(3, autoreverses: false)) {
                pulse = true
            }
        }
    }
}

private struct ReturnLine: View {
    let color: Color
    @State private var returned = false

    var body: some View {
        Rectangle()
            .fill(color)
            .scaleEffect(x: returned ? 1 : 0.02, y: 1, anchor: .trailing)
            .opacity(returned ? 0 : 0.75)
            .onAppear {
                withAnimation(.easeOut(duration: 1.2)) { returned = true }
            }
    }
}

private struct EmptyInbox: View {
    let appearance: JianlingAppearance
    let language: JianlingLanguage
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var palette: JianlingPalette { JianlingPalette(appearance, colorScheme: colorScheme) }

    var body: some View {
        VStack(spacing: 8) {
            Text(language.text("剑令已清", "Inbox clear"))
                .font(.custom("STKaiti", size: 23).weight(.semibold))
                .foregroundStyle(palette.handled)
            Text(language.text("新的复命会安静地回到这里。", "New AI results will return here quietly."))
                .jianlingFont(appearance, size: 10)
                .foregroundStyle(palette.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 6)
        .onAppear {
            withAnimation(.easeOut(duration: 0.28)) { appeared = true }
        }
    }
}

private func relative(_ date: Date, language: JianlingLanguage) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = language.locale
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func toolAsset(_ session: SessionSnapshot) -> String {
    switch session.tool {
    case .craft: return "craft.png"
    case .claudeCode: return "claude.png"
    case .codex: return "codex.png"
    case .newMax: return "newmax.png"
    case .workBuddy: return "workbuddy.svg"
    case .external:
        // Known slugs hit the bundled runtime artwork (hermes.png, …);
        // unknown ones fall through to RuntimeLogo's terminal placeholder.
        return "\(session.externalTool ?? "external").png"
    }
}
