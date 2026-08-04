import AppKit
import Combine
import CompletionBellCore
import SwiftUI

@MainActor
private final class TopNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class TopNotchViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var geometry: NotchGeometry?
    var onToggle: () -> Void = {}
    var onPin: () -> Void = {}
    var onClose: () -> Void = {}
    var onTracking: (Bool) -> Void = { _ in }
}

/// Top-of-screen host for both physical-notched displays and the first-class
/// capsule presentation used by external displays.
@MainActor
final class TopNotchHost {
    private let state: AppState
    private var hover = EdgeHoverStateMachine()
    private let geometryResolver = NotchGeometryResolver()
    private var screenChangeResolver: EdgePlacementResolver
    private let viewModel = TopNotchViewModel()
    private var panel: NSPanel?
    private var tickTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    private var stateObserver: AnyCancellable?
    private var quotaObserver: AnyCancellable?
    private var screenDescriptors: [EdgeScreenDescriptor]
    private var pendingScreenDescriptors: [EdgeScreenDescriptor] = []
    private var notchMenuOpen = false
    private var currentExpanded = false
    private var tickInterval = 0.1

    init(state: AppState) {
        self.state = state
        self.screenDescriptors = RightEdgeHost.screens()
        self.screenChangeResolver = EdgePlacementResolver(initialScreenIDs: Set(screenDescriptors.map(\.id)))
        currentExpanded = hover.send(.pinChanged(state.notchPinned), at: Date()).isExpanded
        viewModel.isExpanded = currentExpanded
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// Paired with `stop()`: panel/content, observers, subscriptions, and the
    /// hover heartbeat are all installed here and fully released there.
    func show() -> Bool {
        if panel == nil {
            screenDescriptors = RightEdgeHost.screens()
            screenChangeResolver = EdgePlacementResolver(initialScreenIDs: Set(screenDescriptors.map(\.id)))
            createPanel()
        }
        guard let panel else { return false }
        guard refreshFrame(animated: false) else {
            stop()
            return false
        }
        panel.orderFrontRegardless()
        installObservers()
        startTicking(interval: 0.1)
        return true
    }

    func close() {
        stop()
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        stateObserver?.cancel()
        stateObserver = nil
        quotaObserver?.cancel()
        quotaObserver = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        menuObservers.removeAll()
        notchMenuOpen = false
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel = nil
        hover = EdgeHoverStateMachine(now: Date())
        _ = hover.send(.pinChanged(state.notchPinned), at: Date())
        currentExpanded = state.notchPinned
        viewModel.isExpanded = currentExpanded
        viewModel.geometry = nil
        pendingScreenDescriptors = []
        screenDescriptors = RightEdgeHost.screens()
        screenChangeResolver = EdgePlacementResolver(initialScreenIDs: Set(screenDescriptors.map(\.id)))
    }

    func setPinned(_ pinned: Bool) {
        guard panel != nil else { return }
        apply(hover.send(.pinChanged(pinned), at: Date()))
    }

    func moveToScreen(_ id: String?) {
        guard panel != nil else { return }
        _ = id
        _ = refreshFrame(animated: false)
    }

    func contentActivated() {
        guard panel != nil else { return }
        apply(hover.send(.contentActivated, at: Date()))
    }

    /// The strip beside the notch exists only while it has something to say:
    /// an unread signal on the left, or quota readouts on the right. Both
    /// slots share the wider width so the strip stays centred on the notch.
    private var compactSlotWidth: Double {
        let pairs = min(2, state.visibleQuotaProviders.count)
        let hasSignal = state.unreadCount > 0 || state.activeCount > 0
        guard hasSignal || pairs > 0 else { return 0 }
        return NotchGeometryResolver.compactSlotWidth(quotaPairs: pairs)
    }

    /// Width the capsule needs for its current content — recomputed whenever
    /// the count gains a digit or a quota gem appears/disappears.
    private var capsuleWidth: Double {
        let count = state.unreadCount > 0 ? state.unreadCount : state.activeCount
        return NotchGeometryResolver.capsuleWidth(
            quotaCount: min(2, state.visibleQuotaProviders.count),
            countDigits: count > 0 ? String(count).count : 1
        )
    }

    private func createPanel() {
        let panel = TopNotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: capsuleWidth, height: NotchGeometryResolver.capsuleHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // AppKit projects the window shadow from the window RECT, so a capsule
        // or bottom-rounded panel gets a rectangular halo that reads as a black
        // outline — and it goes stale when the content resizes. SwiftUI draws
        // the shadow instead, where it follows the actual shape.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .darkAqua)
        self.panel = panel

        viewModel.onToggle = { [weak self] in self?.toggle() }
        viewModel.onPin = { [weak self] in self?.state.notchPinned.toggle() }
        viewModel.onClose = { [weak self] in self?.close() }
        viewModel.onTracking = { [weak self] in self?.trackingChanged($0) }
        panel.contentViewController = NSHostingController(
            rootView: TopNotchContent(state: state, model: viewModel)
                .environment(\.colorScheme, .dark)
                .jianlingFontScale(state.fontScale)
        )

        stateObserver = Publishers.CombineLatest4(
            state.$sessions,
            state.$attentionStates,
            state.$expandedGroupIDs,
            state.$snoozedSessionIDs
        ).sink { [weak self] _, _, _, _ in
            DispatchQueue.main.async { self?.refreshForContentChange() }
        }
        quotaObserver = Publishers.CombineLatest(state.$quotaProviders, state.$energyEnabled).sink { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshForContentChange() }
        }
    }

    private func refreshForContentChange() {
        guard panel != nil else { return }
        _ = refreshFrame(animated: false)
    }

    private func installObservers() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingScreenDescriptors = RightEdgeHost.screens()
                self.screenChangeResolver.noteScreenChange(self.pendingScreenDescriptors, at: Date())
                self.startTicking(interval: 0.1)
            }
        }
        menuObservers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let panel = self.panel,
                          panel.frame.insetBy(dx: -24, dy: -24).contains(NSEvent.mouseLocation) else { return }
                    self.notchMenuOpen = true
                    self.apply(self.hover.send(.menuOpened, at: Date()))
                }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.notchMenuOpen else { return }
                    self.notchMenuOpen = false
                    self.apply(self.hover.send(.menuClosed, at: Date()))
                }
            }
        ]
    }

    private func trackingChanged(_ inside: Bool) {
        apply(hover.send(inside ? .entryEntered : .entryExited, at: Date()))
    }

    private func toggle() {
        apply(hover.send(.entryClicked, at: Date()))
    }

    private func apply(_ snapshot: EdgeHoverSnapshot?) {
        guard let snapshot else { return }
        let changed = currentExpanded != snapshot.isExpanded
        currentExpanded = snapshot.isExpanded
        if changed {
            viewModel.isExpanded = snapshot.isExpanded
            _ = refreshFrame(animated: true)
        }
        if !snapshot.shouldPoll && !screenChangeResolver.hasPendingScreenChange {
            tickTimer?.invalidate()
            tickTimer = nil
        } else {
            startTicking(interval: snapshot.isMoving ? (1.0 / 60.0) : 0.1)
        }
    }

    private func startTicking(interval: TimeInterval) {
        guard panel != nil else { return }
        if tickTimer != nil, abs(tickInterval - interval) < 0.0001 { return }
        tickTimer?.invalidate()
        tickInterval = interval
        tickTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.screenChangeResolver.takeScreenChangeDue(at: Date()) {
                    self.screenDescriptors = self.pendingScreenDescriptors
                    self.pendingScreenDescriptors = []
                    _ = self.refreshFrame(animated: false)
                }
                guard let panel = self.panel else {
                    self.tickTimer?.invalidate()
                    self.tickTimer = nil
                    return
                }
                let hotRegion = panel.frame.insetBy(dx: -14, dy: -14)
                self.apply(self.hover.send(.pointerValidation(isInsideHotRegion: hotRegion.contains(NSEvent.mouseLocation)), at: Date()))
                self.apply(self.hover.advance(to: Date()))
            }
        }
    }

    @discardableResult
    private func refreshFrame(animated: Bool) -> Bool {
        guard let panel else { return false }
        guard let geometry = geometryResolver.resolve(
            screens: screenDescriptors,
            preferredScreenID: state.notchScreenID,
            expandedSize: (PresentationLayout.notchExpandedWidth, expandedHeight),
            capsuleWidth: capsuleWidth,
            compactSlotWidth: compactSlotWidth
        ) else { return false }

        viewModel.geometry = geometry
        // The window is parked at a fixed frame that covers every state. Only
        // the SwiftUI shape inside animates — resizing an NSWindow per frame
        // goes through the window server and stutters, which is exactly what
        // made the old expand feel heavy.
        let frame = NSRect(geometry.hostFrame)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        return true
    }

    private var expandedHeight: Double {
        let groups = (state.routineSessions.isEmpty ? 0 : 1) + (state.backgroundSessions.isEmpty ? 0 : 1)
        let routineCount = state.isExpanded("routine") ? state.routineSessions.count : 0
        let items = state.inboxSessions.count + routineCount + (state.isExpanded("background") ? state.backgroundSessions.count : 0)
        return min(
            PresentationLayout.notchExpandedHeight,
            PresentationLayout.edgePanelHeight(
                itemCount: items,
                groupCount: groups,
                isEmpty: items == 0,
                showsEnergy: false
            )
        )
    }
}

private extension NSRect {
    init(_ rect: EdgeRect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}

private struct TopNotchContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: TopNotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if let geometry = model.geometry {
                switch geometry.presentation {
                case .notch:
                    // One continuous shape that grows out of the physical notch.
                    // Collapsed it is exactly the notch rect, so it is invisible
                    // against the real cutout — no seam, nothing to align.
                    NotchIsland(state: state, model: model, geometry: geometry)
                case .capsule:
                    // Tracking lives INSIDE each form, sized to it. The window
                    // itself is parked at a large fixed frame now, so a
                    // window-wide tracking area would arm the hover from far
                    // below the visible entry.
                    VStack(spacing: 0) {
                        CapsuleCompactEntry(state: state)
                            .frame(width: geometry.collapsedRect.width, height: geometry.collapsedRect.height)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: model.onToggle)
                        if model.isExpanded { expandedPanel }
                    }
                    .background {
                        HostTrackingView(onChange: model.onTracking)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.text("顶部剑令", "Top Bladecall entry"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(
            named: state.text(model.isExpanded ? "收起" : "展开", model.isExpanded ? "Collapse" : "Expand"),
            model.onToggle
        )
    }

    @ViewBuilder
    var expandedPanel: some View {
        PopoverView(
            state: state,
            surface: .notchExpanded,
            onClose: model.onClose,
            onTogglePin: model.onPin
        )
        .shadow(color: .black.opacity(0.20), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.20), radius: 22, y: 9)
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }
}

private struct CapsuleCompactEntry: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var pulse = false
    private let palette = JianlingPalette(.modern, colorScheme: .dark)

    private var count: Int { state.unreadCount > 0 ? state.unreadCount : state.activeCount }
    private var statusColor: Color {
        if state.unreadCount > 0 { return palette.unread }
        if state.activeCount > 0 { return palette.running }
        return palette.tertiaryText
    }

    var body: some View {
        // A horizontal strip needs its own composition — the vertical tag's
        // stack put the provider letter *under* the gem, which introduced a
        // second baseline in a 34pt bar and left the ends stranded by a Spacer.
        // Everything here sits on one optical line, and the strip is sized to
        // its content instead of a fixed width.
        HStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                JianlingSeal(size: 17)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                if count > 0 {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: statusColor.opacity(0.55), radius: 2)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                        .scaleEffect(pulse ? 1.45 : 1)
                        .offset(x: 2.5, y: -2.5)
                }
            }
            // The dot already says "something happened"; the word did not add
            // anything the number and colour were not already carrying.
            Text(count > 0 ? "\(count)" : state.text("清", "–"))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(count == 0 ? palette.tertiaryText : palette.text)

            if !quotaBadges.isEmpty {
                Rectangle()
                    .fill(palette.secondaryText.opacity(0.22))
                    .frame(width: 0.5, height: 16)
                    .padding(.horizontal, 1)
                HStack(spacing: 8) {
                    ForEach(quotaBadges) { badge in
                        QuotaGem(
                            percent: badge.remainingPercent,
                            label: badge.provider == .codex ? "X" : "C",
                            palette: palette,
                            metrics: .medium,
                            labelTint: palette.secondaryText,
                            layout: .inline
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(height: NotchGeometryResolver.capsuleHeight)
        .background { compactBackground }
        .clipShape(Capsule())
        .overlay {
            // Edge lighting rather than a stroke: a hard outline reads as a
            // border drawn on top, not as the lit edge of a physical object.
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
                .blendMode(.plusLighter)
        }
        // Two layers rather than one heavy drop: a tight contact shadow that
        // seats the capsule, and a wide ambient one that lifts it. A single
        // 0.3/9pt shadow reads as a dark rim at this size.
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
        .opacity(count == 0 ? 0.72 : 1)
        .onChange(of: state.unreadCount) { value in
            guard value > 0, state.motionEnabled, !reduceMotion else { return }
            pulse = false
            withAnimation(.easeOut(duration: 0.28)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeOut(duration: 0.4)) { pulse = false }
            }
        }
    }

    private var quotaBadges: [QuotaBadgeData] {
        state.visibleQuotaProviders.prefix(2).compactMap { provider in
            guard let window = provider.compactWindow else { return nil }
            return QuotaBadgeData(provider: provider.provider, remainingPercent: window.remainingPercent)
        }
    }

    private var statusText: String {
        if state.unreadCount > 0 { return state.text("\(state.unreadCount) 复命", "\(state.unreadCount) ready") }
        if state.activeCount > 0 { return state.text("\(state.activeCount) 行剑", "\(state.activeCount) active") }
        return state.text("清", "Clear")
    }

    @ViewBuilder
    private var compactBackground: some View {
        if reduceTransparency {
            palette.surface
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                // 0.74 of a near-black surface reads as a black blob on a dark
                // desktop; a lighter tint keeps it a translucent object.
                palette.raised.opacity(0.62)
            }
        }
    }

    private func pulseUnreadOnce() {
        guard state.unreadCount > 0, state.motionEnabled, !reduceMotion else { return }
        pulse = false
        withAnimation(.easeOut(duration: 0.7)) { pulse = true }
    }
}



/// The notch form: a single shape anchored to the top of the screen that
/// interpolates between the physical notch's own rect and the expanded panel.
/// Because the window never moves, the growth is a pure SwiftUI/GPU animation —
/// the reason this reads smooth where a window-resize did not.
private struct NotchIsland: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: TopNotchViewModel
    let geometry: NotchGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let palette = JianlingPalette(.modern, colorScheme: .dark)

    private var expanded: Bool { model.isExpanded }
    private var hasSlots: Bool { geometry.collapsedRect.width > geometry.notchRect.width + 1 }
    private var slotWidth: CGFloat { max(0, (geometry.collapsedRect.width - geometry.notchRect.width) / 2) }
    /// Concave wing where the shape meets the screen top. Zero while the strip
    /// is invisible — a flare beside the bare notch would paint black over the
    /// menu bar.
    private var flare: CGFloat {
        if expanded { return NotchGeometryResolver.expandedTopCornerRadius }
        return hasSlots ? NotchGeometryResolver.compactTopFlareRadius : 0
    }
    /// The flare wings live outside the content rect, so the frame is widened
    /// by one flare each side and the body keeps its resolved width.
    private var width: CGFloat {
        (expanded ? geometry.expandedRect.width : geometry.collapsedRect.width) + flare * 2
    }
    private var height: CGFloat { expanded ? geometry.expandedRect.height : geometry.collapsedRect.height }
    private var motion: Bool { state.motionEnabled && !reduceMotion }

    /// Opening: height leads with a touch of bounce (the shape pours down out
    /// of the notch), width follows a beat later and settles without overshoot
    /// (it spreads). Closing reverses the order: width snaps back to the notch
    /// first, then the height draws up — the shape is sucked back in. This
    /// asymmetric choreography is what reads as "flowing", where a single
    /// synchronized spring reads as a photo being scaled.
    private var widthAnimation: Animation {
        guard motion else { return .easeOut(duration: 0.12) }
        return expanded
            ? .spring(response: 0.55, dampingFraction: 0.86)
            : .spring(response: 0.30, dampingFraction: 0.92)
    }

    private var heightAnimation: Animation {
        guard motion else { return .easeOut(duration: 0.12) }
        return expanded
            ? .spring(response: 0.42, dampingFraction: 0.74)
            : .spring(response: 0.42, dampingFraction: 0.9)
    }

    var body: some View {
        // Constant black at every point of the animation. Fading a material
        // in mid-flight was a visible texture pop; the physical notch is
        // black, so the growing shape stays black and simply reveals rows.
        //
        // The panel and the compact readout ride as overlays rather than
        // stack siblings: a ZStack takes the union of its children's sizes,
        // so the fixed 420×560 panel inflated the stack and the outer
        // height frame re-centred everything 260pt above the visible band —
        // black still showed (it fills flexibly) but the readout never did.
        // Overlays are layout-inert: they anchor to the black shape's own
        // top edge no matter what state the shape is in.
        Color.black
            .overlay(alignment: .top) {
                PopoverView(
                    state: state,
                    surface: .notchExpanded,
                    onClose: model.onClose,
                    onTogglePin: model.onPin
                )
                .frame(width: geometry.expandedRect.width, height: geometry.expandedRect.height)
                // Content waits for the shape to be most of the way open, then
                // fades in; on close it vanishes first so the shape retracts empty.
                .opacity(expanded ? 1 : 0)
                .animation(
                    expanded
                        ? .easeOut(duration: 0.22).delay(motion ? 0.14 : 0)
                        : .easeOut(duration: 0.08),
                    value: expanded
                )
                .allowsHitTesting(expanded)
            }
            .overlay(alignment: .top) {
                // Compact readout riding the collapsed strip, in the volume-HUD
                // grammar: the left slot carries the "come look" signal — a blue
                // message mark that exists only while finished sessions await
                // review — and the right slot keeps the two quota numbers worth
                // a glance, each behind its runtime's own mark (Codex weekly,
                // Claude five-hour). It fades first on expand so the shape
                // opens empty, and returns after collapse.
                if hasSlots {
                    HStack(spacing: 0) {
                        leftSlot
                            .frame(width: slotWidth, alignment: .leading)
                        Spacer(minLength: geometry.notchRect.width)
                        rightSlot
                            .frame(width: slotWidth, alignment: .trailing)
                    }
                    .frame(width: geometry.collapsedRect.width, height: geometry.notchRect.height)
                    .opacity(expanded ? 0 : 1)
                    .animation(
                        expanded
                            ? .easeOut(duration: 0.08)
                            : .easeOut(duration: 0.18).delay(motion ? 0.12 : 0),
                        value: expanded
                    )
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(compactAccessibilityLabel)
                }
            }
            .background {
                HostTrackingView(onChange: model.onTracking)
                    .allowsHitTesting(false)
            }
            .frame(width: width)
        .animation(widthAnimation, value: expanded)
        .frame(height: height)
        .clipShape(NotchIslandShape(
            topRadius: flare,
            bottomRadius: expanded
                ? NotchGeometryResolver.expandedBottomCornerRadius
                : (hasSlots ? NotchGeometryResolver.compactCornerRadius : 0)
        ))
        .shadow(color: .black.opacity(expanded ? 0.32 : 0), radius: 18, y: 8)
        .animation(heightAnimation, value: expanded)
        .contentShape(Rectangle())
        .onTapGesture(perform: model.onToggle)
    }

    /// Blue message = finished sessions waiting to be seen; the quiet running
    /// dot fills in when swords are out but nothing needs the user yet.
    @ViewBuilder
    private var leftSlot: some View {
        if state.unreadCount > 0 {
            HStack(spacing: 4.5) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.unread)
                    .shadow(color: palette.unread.opacity(0.45), radius: 3)
                Text("\(state.unreadCount)")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(.leading, 14)
        } else if state.activeCount > 0 {
            Circle()
                .fill(palette.running.opacity(0.9))
                .frame(width: 5.5, height: 5.5)
                .padding(.leading, 17)
        }
    }

    @ViewBuilder
    private var rightSlot: some View {
        if !quotaReadouts.isEmpty {
            HStack(spacing: 7) {
                ForEach(quotaReadouts) { readout in
                    HStack(spacing: 2.5) {
                        RuntimeLogo(
                            assetName: readout.provider == .codex ? "codex.png" : "claude.png",
                            size: 11.5,
                            appearance: state.appearance
                        )
                        .opacity(0.92)
                        Text("\(Int(readout.remainingPercent.rounded()))")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(quotaTextColor(readout.remainingPercent))
                    }
                }
            }
            .padding(.trailing, 13)
        }
    }

    /// Codex's weekly window, Claude's five-hour window — the convention the
    /// compact surfaces share via `compactWindow`.
    private var quotaReadouts: [QuotaBadgeData] {
        state.visibleQuotaProviders.prefix(2).compactMap { provider in
            guard let window = provider.compactWindow else { return nil }
            return QuotaBadgeData(provider: provider.provider, remainingPercent: window.remainingPercent)
        }
    }

    /// Colour only as a warning channel: healthy numbers stay quiet white so
    /// the strip does not read as a traffic light.
    private func quotaTextColor(_ percent: Double) -> Color {
        switch QuotaTier.tier(forRemainingPercent: percent) {
        case .full, .good: return .white.opacity(0.85)
        case .low: return palette.quotaColor(.low)
        case .critical: return palette.quotaColor(.critical)
        }
    }

    private var compactAccessibilityLabel: String {
        var parts: [String] = []
        if state.unreadCount > 0 {
            parts.append(state.text("\(state.unreadCount) 枚复命待看", "\(state.unreadCount) finished awaiting review"))
        } else if state.activeCount > 0 {
            parts.append(state.text("\(state.activeCount) 柄行剑中", "\(state.activeCount) running"))
        }
        for readout in quotaReadouts {
            let name = readout.provider == .codex ? "Codex" : "Claude"
            parts.append("\(name) \(Int(readout.remainingPercent.rounded()))%")
        }
        return state.text("剑令，", "Bladecall, ") + parts.joined(separator: state.text("，", ", "))
    }
}

/// The notch profile: concave flares where the outer top corners meet the
/// screen edge (the shape flows out of the menu bar, exactly the system
/// volume HUD's silhouette) and convex corners at the bottom. `topRadius` is
/// the flare — the body of the shape is inset by one flare on each side, so
/// callers widen their frame accordingly.
private struct NotchIslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let bottom = max(0, min(bottomRadius, rect.width / 2 - top, rect.height - top))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Left flare: hugging the screen top, then turning down into the body.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        // Right flare, mirrored, back up to the screen edge.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
