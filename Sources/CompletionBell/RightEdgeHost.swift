import AppKit
import Combine
import CompletionBellCore
import CoreGraphics
import SwiftUI

@MainActor
private final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class EdgeHostViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var dockConflict = false
    @Published var fluidDeformation = EdgeFluidDeformation.zero
    @Published var compactHeight = PresentationLayout.edgeTagHeight
    @Published var tagSize: EdgeTagSize = .medium
    @Published var screenChoices: [EdgeScreenChoice] = []
    @Published var selectedScreenID: String?
    var onToggle: () -> Void = {}
    var onPin: () -> Void = {}
    var onClose: () -> Void = {}
    var onTracking: (Bool) -> Void = { _ in }
    var onDrag: (CGSize, Bool) -> Void = { _, _ in }
    var onSelectScreen: (String) -> Void = { _ in }
}

@MainActor
final class RightEdgeHost {
    private enum Keys {
        static let screenID = "jianlingRightEdgeScreenID"
        static let verticalRatio = "jianlingRightEdgeVerticalRatio"
    }

    private let state: AppState
    private var hover = EdgeHoverStateMachine()
    private var fluid = EdgeFluidDeformationModel()
    private let placementResolver: EdgePlacementResolver
    private let viewModel = EdgeHostViewModel()
    private var panel: NSPanel?
    private var tickTimer: Timer?
    private var fluidTimer: Timer?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    private var stateObserver: AnyCancellable?
    private var quotaObserver: AnyCancellable?
    private var dragStartY: CGFloat?
    private var dockConflict = false
    private var screenDescriptors: [EdgeScreenDescriptor]
    private var pendingScreenDescriptors: [EdgeScreenDescriptor] = []
    private var edgeMenuOpen = false
    private var lastPointerLocation = NSEvent.mouseLocation

    init(state: AppState) {
        self.state = state
        self.screenDescriptors = Self.screens()
        self.placementResolver = EdgePlacementResolver(initialScreenIDs: Set(screenDescriptors.map(\.id)))
        currentExpanded = hover.send(.pinChanged(state.edgePinned), at: Date()).isExpanded
        viewModel.isExpanded = currentExpanded
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show() -> Bool {
        if panel == nil { createPanel() }
        guard let panel else { return false }
        guard refreshFrame(animated: false) else {
            stop()
            return false
        }
        panel.orderFrontRegardless()
        installObservers()
        updateFluid(pointer: NSEvent.mouseLocation, at: Date())
        startTicking(interval: 0.1)
        return true
    }

    func close() {
        stop()
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        fluidTimer?.invalidate()
        fluidTimer = nil
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        stateObserver?.cancel()
        stateObserver = nil
        quotaObserver?.cancel()
        quotaObserver = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        menuObservers.removeAll()
        edgeMenuOpen = false
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel = nil
        hover = EdgeHoverStateMachine(now: Date())
        _ = hover.send(.pinChanged(state.edgePinned), at: Date())
        fluid = EdgeFluidDeformationModel(now: Date())
        viewModel.fluidDeformation = .zero
        currentExpanded = state.edgePinned
        viewModel.isExpanded = currentExpanded
        dragStartY = nil
        dockConflict = false
    }

    func setPinned(_ pinned: Bool) {
        guard panel != nil else { return }
        apply(hover.send(.pinChanged(pinned), at: Date()))
    }

    /// Re-lay the tag after the user picks a different footprint.
    func resizeTag() {
        guard panel != nil else { return }
        viewModel.tagSize = state.edgeTagSize
        rebuildContent()
        _ = refreshFrame(animated: false)
    }

    /// Move the tag to another display. `nil` restores the automatic choice.
    func moveToScreen(_ id: String?) {
        guard panel != nil else { return }
        rebuildContent()
        _ = refreshFrame(animated: false)
        _ = id
    }

    func contentActivated() {
        guard panel != nil else { return }
        apply(hover.send(.contentActivated, at: Date()))
    }

    private func createPanel() {
        let panel = EdgePanel(
            contentRect: NSRect(x: 0, y: 0, width: state.edgeTagSize.hitWidth, height: state.edgeTagSize.baseHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .aqua)
        self.panel = panel
        rebuildContent()
        stateObserver = Publishers.CombineLatest4(
            state.$sessions,
            state.$attentionStates,
            state.$expandedGroupIDs,
            state.$snoozedSessionIDs
        ).sink { [weak self] _, _, _, _ in
            DispatchQueue.main.async { self?.refreshFrame(animated: false) }
        }
        quotaObserver = Publishers.CombineLatest(state.$quotaProviders, state.$energyEnabled).sink { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.rebuildContent()
                _ = self.refreshFrame(animated: false)
            }
        }
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
                self.pendingScreenDescriptors = Self.screens()
                self.placementResolver.noteScreenChange(self.pendingScreenDescriptors, at: Date())
                self.startTicking(interval: 0.1)
            }
        }
        menuObservers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let panel = self.panel,
                          panel.frame.insetBy(dx: -24, dy: -24).contains(NSEvent.mouseLocation) else { return }
                    self.edgeMenuOpen = true
                    self.apply(self.hover.send(.menuOpened, at: Date()))
                }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.edgeMenuOpen else { return }
                    self.edgeMenuOpen = false
                    self.apply(self.hover.send(.menuClosed, at: Date()))
                }
            }
        ]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.updateFluid(pointer: location, at: Date()) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.updateFluid(pointer: location, at: Date()) }
            return event
        }
    }

    private func trackingChanged(_ inside: Bool) {
        apply(hover.send(inside ? .entryEntered : .entryExited, at: Date()))
    }

    private func toggle() {
        apply(hover.send(.entryClicked, at: Date()))
    }

    private func apply(_ snapshot: EdgeHoverSnapshot?) {
        guard let snapshot else { return }
        let wasExpanded = currentExpanded
        currentExpanded = snapshot.isExpanded
        if wasExpanded != snapshot.isExpanded {
            _ = refreshFrame(animated: false)
            viewModel.isExpanded = snapshot.isExpanded
            updateFluid(pointer: lastPointerLocation, at: Date())
        }
        if (!snapshot.shouldPoll)
            && !placementResolver.hasPendingScreenChange {
            tickTimer?.invalidate()
            tickTimer = nil
        } else {
            startTicking(interval: snapshot.isMoving ? (1.0 / 60.0) : 0.1)
        }
    }

    private var currentExpanded = false

    private var compactHeight: Double {
        state.edgeTagSize.height(quotaRowCount: state.visibleQuotaProviders.count)
    }

    private var tickInterval = 0.1

    private func startTicking(interval: TimeInterval) {
        guard panel != nil else { return }
        if tickTimer != nil, abs(tickInterval - interval) < 0.0001 { return }
        tickTimer?.invalidate()
        tickInterval = interval
        tickTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.placementResolver.takeScreenChangeDue(at: Date()) {
                    self.screenDescriptors = self.pendingScreenDescriptors
                    self.pendingScreenDescriptors = []
                    self.rebuildContent()
                    _ = self.refreshFrame(animated: false)
                }
                guard let panel = self.panel else {
                    self.tickTimer?.invalidate()
                    self.tickTimer = nil
                    return
                }
                let inside = panel.frame.insetBy(dx: -14, dy: -14).contains(NSEvent.mouseLocation)
                self.apply(self.hover.send(.pointerValidation(isInsideHotRegion: inside), at: Date()))
                self.apply(self.hover.advance(to: Date()))
            }
        }
    }

    private func updateFluid(pointer: NSPoint, at now: Date) {
        guard let panel else { return }
        lastPointerLocation = pointer
        let threshold = PresentationLayout.edgeFluidProximityThreshold
        let allowsMotion = state.motionEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let tagRect = EdgeRect(
            x: panel.frame.maxX - state.edgeTagSize.visualWidth,
            y: panel.frame.midY - compactHeight / 2,
            width: state.edgeTagSize.visualWidth,
            height: compactHeight
        )
        // A collapsed, already-clean tag does no deformation work for remote
        // mouse moves. The first exit sample still runs so it can clear the
        // paired entry deformation immediately.
        if allowsMotion,
           !currentExpanded,
           fluidTimer == nil,
           viewModel.fluidDeformation == .zero,
           distance(from: pointer, to: tagRect) >= threshold {
            return
        }
        let deformation = fluid.update(
            pointer: EdgePoint(x: pointer.x, y: pointer.y),
            tagRect: tagRect,
            proximityThreshold: threshold,
            allowsMotion: allowsMotion,
            isExpanded: currentExpanded,
            at: now
        )
        if viewModel.fluidDeformation != deformation {
            viewModel.fluidDeformation = deformation
        }
        if deformation.needsAnimation {
            startFluidAnimation()
        } else {
            fluidTimer?.invalidate()
            fluidTimer = nil
        }
    }

    private func distance(from point: NSPoint, to rect: EdgeRect) -> Double {
        let closestX = min(rect.maxX, max(rect.minX, point.x))
        let closestY = min(rect.maxY, max(rect.minY, point.y))
        return hypot(point.x - closestX, point.y - closestY)
    }

    private func startFluidAnimation() {
        guard fluidTimer == nil, panel != nil else { return }
        fluidTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel != nil else { return }
                self.updateFluid(pointer: self.lastPointerLocation, at: Date())
            }
        }
    }

    private func rebuildContent() {
        guard let panel else { return }
        viewModel.dockConflict = dockConflict
        viewModel.compactHeight = compactHeight
        if viewModel.tagSize != state.edgeTagSize { viewModel.tagSize = state.edgeTagSize }
        viewModel.screenChoices = Self.screenChoices(from: screenDescriptors)
        viewModel.selectedScreenID = UserDefaults.standard.string(forKey: Keys.screenID)
        viewModel.onToggle = { [weak self] in self?.toggle() }
        viewModel.onPin = { [weak self] in self?.state.edgePinned.toggle() }
        viewModel.onClose = { [weak self] in self?.close() }
        viewModel.onTracking = { [weak self] in self?.trackingChanged($0) }
        viewModel.onDrag = { [weak self] translation, ended in self?.drag(translation: translation, ended: ended) }
        viewModel.onSelectScreen = { [weak self] id in
            // Route through AppState so the Settings picker and the tag's own
            // menu never disagree; AppState persists and calls moveToScreen.
            self?.state.edgeScreenID = id
        }
        guard panel.contentViewController == nil else { return }
        panel.contentViewController = NSHostingController(
            rootView: RightEdgeContent(state: state, model: viewModel)
            .environment(\.colorScheme, .light)
            .jianlingFontScale(state.fontScale)
        )
    }

    @discardableResult
    private func refreshFrame(animated: Bool) -> Bool {
        guard let panel else { return false }
        let ratio = UserDefaults.standard.object(forKey: Keys.verticalRatio) as? Double ?? 0.5
        let screenID = UserDefaults.standard.string(forKey: Keys.screenID)
        let width = currentExpanded ? PresentationLayout.edgeExpandedWidth : state.edgeTagSize.hitWidth
        let height = currentExpanded ? expandedHeight : compactHeight
        guard let placement = placementResolver.resolve(
            screens: screenDescriptors,
            preference: EdgePlacementPreference(screenID: screenID, verticalRatio: ratio),
            size: (width, height),
            tagHeight: compactHeight
        ) else { return false }
        if screenID != placement.screenID { UserDefaults.standard.set(placement.screenID, forKey: Keys.screenID) }
        let conflictChanged = dockConflict != placement.dockConflict
        dockConflict = placement.dockConflict
        if conflictChanged { viewModel.dockConflict = dockConflict }
        let frame = NSRect(x: placement.frame.x, y: placement.frame.y, width: placement.frame.width, height: placement.frame.height)
        // The collapsed tag needs an ambient shadow too — without one it looks
        // painted onto the wallpaper instead of resting above it.
        panel.hasShadow = true
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        return true
    }

    private var expandedHeight: Double {
        let groups = (state.routineSessions.isEmpty ? 0 : 1) + (state.backgroundSessions.isEmpty ? 0 : 1)
        let routineCount = state.isExpanded("routine") ? state.routineSessions.count : 0
        let items = state.inboxSessions.count + routineCount + (state.isExpanded("background") ? state.backgroundSessions.count : 0)
        return PresentationLayout.edgePanelHeight(
            itemCount: items,
            groupCount: groups,
            isEmpty: items == 0,
            showsEnergy: !state.visibleQuotaProviders.isEmpty
        )
    }

    private func drag(translation: CGSize, ended: Bool) {
        guard let panel, let screen = Self.screen(containing: panel.frame),
              let displayID = Self.descriptor(for: screen)?.id,
              let descriptor = screenDescriptors.first(where: { $0.id == displayID }) else { return }
        if dragStartY == nil { dragStartY = panel.frame.minY }
        let targetY = (dragStartY ?? panel.frame.minY) - translation.height
        let ratio = placementResolver.verticalRatio(forY: targetY, screen: descriptor, height: panel.frame.height, tagHeight: compactHeight)
        if let candidate = placementResolver.resolve(
               screens: [descriptor],
               preference: EdgePlacementPreference(screenID: descriptor.id, verticalRatio: ratio),
               size: currentExpanded
                   ? (PresentationLayout.edgeExpandedWidth, expandedHeight)
                   : (state.edgeTagSize.hitWidth, compactHeight),
               tagHeight: compactHeight
           ),
           abs(candidate.frame.y - panel.frame.minY) < 0.5 {
            if ended { dragStartY = nil }
            return
        }
        UserDefaults.standard.set(descriptor.id, forKey: Keys.screenID)
        UserDefaults.standard.set(ratio, forKey: Keys.verticalRatio)
        refreshFrame(animated: false)
        if ended { dragStartY = nil }
    }

    static func screens() -> [EdgeScreenDescriptor] {
        NSScreen.screens.compactMap(descriptor(for:))
    }

    static func screenChoices(from descriptors: [EdgeScreenDescriptor]) -> [EdgeScreenChoice] {
        let names = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (String, String)? in
            guard let descriptor = descriptor(for: screen) else { return nil }
            return (descriptor.id, screen.localizedName)
        })
        return descriptors.map { EdgeScreenChoice(id: $0.id, title: names[$0.id] ?? $0.id) }
    }

    private static func descriptor(for screen: NSScreen) -> EdgeScreenDescriptor? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard displayID != 0, let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        let id = CFUUIDCreateString(nil, cfUUID) as String
        return EdgeScreenDescriptor(
            id: id,
            frame: EdgeRect(screen.frame),
            visibleFrame: EdgeRect(screen.visibleFrame),
            isMain: screen == NSScreen.main,
            // Ghost displays reported during sleep/wake are offline or
            // inactive. CGDisplayUnitNumber is NOT a validity test — real
            // displays legitimately start at unit 0 (the built-in panel does),
            // which previously flagged every screen invalid and left the edge
            // host unable to place itself at all.
            isValid: CGDisplayIsActive(displayID) != 0 && CGDisplayIsOnline(displayID) != 0,
            safeAreaTop: screen.safeAreaInsets.top,
            safeAreaBottom: screen.safeAreaInsets.bottom,
            // The unobstructed menu-bar rects either side of the cutout. Their
            // remainder is the real notch width — 14" and 16" differ, and a
            // scaled resolution changes both, so the 200pt guess is a last resort.
            auxiliaryLeftWidth: Double(screen.auxiliaryTopLeftArea?.width ?? 0),
            auxiliaryRightWidth: Double(screen.auxiliaryTopRightArea?.width ?? 0)
        )
    }

    private static func screen(containing frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        } ?? NSScreen.main
    }
}

private extension EdgeRect {
    init(_ rect: NSRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

struct EdgeScreenChoice: Identifiable {
    let id: String
    let title: String
}

private struct RightEdgeContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: EdgeHostViewModel

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if model.isExpanded {
                    PopoverView(state: state, surface: .edgeExpanded, onClose: model.onClose, onTogglePin: model.onPin)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if model.isExpanded {
                    EdgeTagHitArea(state: state, model: model)
                        .frame(width: model.tagSize.hitWidth)
                        .frame(maxHeight: .infinity)
                } else {
                    EdgeTagHitArea(state: state, model: model)
                        .frame(width: model.tagSize.hitWidth, height: model.compactHeight)
                }
            }
            HostTrackingView(onChange: model.onTracking)
                .allowsHitTesting(false)
        }
        .background(Color.clear)
    }
}

private struct EdgeTagHitArea: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: EdgeHostViewModel

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.clear
            FluidEdgeSurface(
                state: state,
                deformation: model.fluidDeformation,
                tagSize: model.tagSize
            )
            .frame(width: model.tagSize.hitWidth)
            .frame(maxHeight: .infinity)
            .allowsHitTesting(false)
            EdgeTagView(state: state, dockConflict: model.dockConflict, fusionProgress: model.fluidDeformation.fusionProgress)
                .frame(width: model.tagSize.visualWidth, height: model.compactHeight)
        }
        .frame(width: model.tagSize.hitWidth)
        .contentShape(Rectangle())
        .onTapGesture(perform: model.onToggle)
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { model.onDrag($0.translation, false) }
                .onEnded { model.onDrag($0.translation, true) }
        )
        .contextMenu {
            if model.screenChoices.count > 1 {
                Menu(state.text("移到显示器", "Move to display")) {
                    ForEach(model.screenChoices) { screen in
                        Button { model.onSelectScreen(screen.id) } label: {
                            if screen.id == model.selectedScreenID {
                                Label(screen.title, systemImage: "checkmark")
                            } else {
                                Text(screen.title)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.text("右侧藏锋，\(state.unreadCount > 0 ? state.unreadCount : state.activeCount) 枚剑令", "Bladecall edge entry, \(state.unreadCount > 0 ? state.unreadCount : state.activeCount) items"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(
            named: state.text(model.isExpanded ? "收起" : "展开", model.isExpanded ? "Collapse" : "Expand"),
            model.onToggle
        )
    }
}

private struct FluidEdgeSurface: View {
    @ObservedObject var state: AppState
    let deformation: EdgeFluidDeformation
    let tagSize: EdgeTagSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var palette: JianlingPalette { JianlingPalette(state.appearance) }
    private var count: Int { state.unreadCount > 0 ? state.unreadCount : state.activeCount }

    @ViewBuilder
    var body: some View {
        if state.motionEnabled && !reduceMotion {
            fusionSurface
                .mask { FluidMetaballMask(deformation: deformation, visualWidth: tagSize.visualWidth) }
        } else {
            // Exact non-fluid fallback used before the metaball treatment.
            surface(opacity: count == 0 ? 0.42 : 0.58)
                .frame(width: tagSize.hitWidth)
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var fusionSurface: some View {
        let progress = CGFloat(min(1, max(0, deformation.fusionProgress)))
        ZStack {
            if reduceTransparency {
                palette.edgeSurface.opacity(1 - progress)
                palette.surface.opacity(progress)
            } else {
                Rectangle().fill(.ultraThinMaterial)
                palette.edgeSurface.opacity((1 - progress) * collapsedTint)
                palette.surface.opacity(progress * 0.42)
            }
            edgeLighting
        }
    }

    @ViewBuilder
    private func surface(opacity: Double) -> some View {
        if reduceTransparency {
            palette.edgeSurface
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                palette.edgeSurface.opacity(opacity)
                edgeLighting
            }
        }
    }

    /// The material alone reads flat. A hairline of light along the top edge
    /// and a shade along the bottom give the tag a physical top surface — the
    /// same trick that makes Control Center modules feel like objects rather
    /// than painted rectangles. Both are sub-pixel-thin on purpose.
    @ViewBuilder
    private var edgeLighting: some View {
        if !reduceTransparency {
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.20), location: 0),
                    .init(color: .white.opacity(0.045), location: 0.06),
                    .init(color: .clear, location: 0.32),
                    .init(color: .black.opacity(0.10), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }

    /// Apple keeps the tint light and lets the wallpaper carry the surface.
    /// The old 0.58 read as dark plastic laid over glass.
    private var collapsedTint: Double { count == 0 ? 0.30 : 0.40 }
}

private struct FluidMetaballMask: View {
    let deformation: EdgeFluidDeformation
    let visualWidth: Double

    var body: some View {
        Canvas { context, size in
            context.addFilter(.alphaThreshold(min: 0.46, color: .white))
            context.addFilter(.blur(radius: 5.5))
            context.drawLayer { layer in
                let visualWidth = CGFloat(self.visualWidth)
                let tag = CGRect(
                    x: size.width - visualWidth,
                    y: 4,
                    width: visualWidth,
                    height: max(1, size.height - 8)
                )
                layer.fill(
                    Path(roundedRect: tag, cornerRadius: 9),
                    with: .color(.white)
                )

                let amplitude = CGFloat(deformation.bulgeAmplitude)
                if amplitude > 0.0001 {
                    let radius = 5 + amplitude * 10
                    let directionX = CGFloat(deformation.bulgeDirectionX)
                    // Core uses AppKit's bottom-up coordinates; Canvas is top-down.
                    let directionY = -CGFloat(deformation.bulgeDirectionY)
                    let center = CGPoint(
                        x: tag.minX + 3 + directionX * amplitude * 9,
                        y: tag.midY + directionY * amplitude * 25
                    )
                    layer.fill(
                        Path(ellipseIn: CGRect(
                            x: center.x - radius,
                            y: center.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )),
                        with: .color(.white)
                    )
                }

                let fusion = CGFloat(deformation.fusionProgress)
                let neck = CGFloat(deformation.bridgeNeckWidth)
                if fusion > 0.0001 || neck > 0.0001 {
                    let neckHeight = 5 + neck * 24
                    let reach = min(tag.minX + 7, 5 + fusion * (tag.minX + 2))
                    let bridge = CGRect(
                        x: 0,
                        y: tag.midY - neckHeight / 2,
                        width: max(1, reach),
                        height: neckHeight
                    )
                    layer.fill(
                        Path(roundedRect: bridge, cornerRadius: neckHeight / 2),
                        with: .color(.white)
                    )
                    let bridgeOrb = 6 + fusion * 8
                    layer.fill(
                        Path(ellipseIn: CGRect(
                            x: max(0, reach - bridgeOrb * 1.3),
                            y: tag.midY - bridgeOrb,
                            width: bridgeOrb * 2,
                            height: bridgeOrb * 2
                        )),
                        with: .color(.white)
                    )
                }
            }
        }
    }
}

private struct EdgeTagView: View {
    @ObservedObject var state: AppState
    let dockConflict: Bool
    let fusionProgress: Double
    @State private var pulse = false

    private var palette: JianlingPalette { JianlingPalette(state.appearance) }
    private var count: Int { state.unreadCount > 0 ? state.unreadCount : state.activeCount }
    private var quotaBadges: [QuotaBadgeData] {
        state.visibleQuotaProviders.compactMap { provider in
            guard let window = provider.compactWindow else { return nil }
            return QuotaBadgeData(provider: provider.provider, remainingPercent: window.remainingPercent)
        }
    }
    private var fusion: Double { min(1, max(0, fusionProgress)) }
    private var metrics: EdgeTagSize { state.edgeTagSize }

    /// The dot sits on top of the logo, so its ring must match whatever the tag
    /// surface currently is — dark when collapsed, panel-tinted once fused.
    private var tagSurfaceTint: Color {
        blended(palette.edgeSurface, palette.surface, amount: fusionProgress)
    }

    private var countColor: Color {
        blended(palette.edgeText, palette.text, amount: fusionProgress)
            .opacity(count == 0 ? 0.45 : 1)
    }

    private var statusColor: Color {
        if state.unreadCount > 0 { return Color(rgb: 0x5A9BFF) }
        if state.activeCount > 0 { return Color(rgb: 0xDF8A26) }
        return .white.opacity(0.32)
    }

    private func blended(_ from: Color, _ to: Color, amount: Double) -> Color {
        let a = NSColor(from).usingColorSpace(.deviceRGB) ?? .white
        let b = NSColor(to).usingColorSpace(.deviceRGB) ?? .white
        let t = CGFloat(min(1, max(0, amount)))
        return Color(nsColor: NSColor(
            calibratedRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: 1
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 身份 + 状态：真实印记 logo 承担身份，右上角状态点承担「有没有事」，
            // 两者叠在同一个位置上，不再各占一行。
            ZStack(alignment: .topTrailing) {
                JianlingSeal(size: metrics.sealSize)
                    .opacity(count == 0 ? 0.55 : 1)
                    .clipShape(RoundedRectangle(cornerRadius: metrics.sealSize * 0.22, style: .continuous))
                if count > 0 {
                    ZStack {
                        if state.motionEnabled {
                            Circle()
                                .stroke(statusColor.opacity(0.5), lineWidth: 1)
                                .frame(width: metrics.statusDotSize * 2.1, height: metrics.statusDotSize * 2.1)
                                .scaleEffect(pulse ? 1.6 : 0.7)
                                .opacity(pulse ? 0 : 1)
                        }
                        Circle()
                            .fill(statusColor)
                            .frame(width: metrics.statusDotSize, height: metrics.statusDotSize)
                            // A soft halo separates the dot from the logo it
                            // sits on; a hard ring would read as a sticker.
                            .shadow(color: statusColor.opacity(0.55), radius: 2.5)
                            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    }
                    .offset(x: metrics.statusDotSize * 0.42, y: -metrics.statusDotSize * 0.42)
                }
            }
            Text(count > 0 ? "\(count)" : state.text("清", "–"))
                .font(.system(size: metrics.countFontSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(countColor)
                .padding(.top, 4)

            if !quotaBadges.isEmpty {
                // 组间松：分隔线把「收件箱」与「剑气」切成两个语义区。
                Rectangle()
                    .fill(blended(palette.edgeText, palette.text, amount: fusionProgress).opacity(0.13))
                    .frame(height: 0.5)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                VStack(spacing: 5) {
                    ForEach(quotaBadges) { badge in
                        QuotaGem(
                            percent: badge.remainingPercent,
                            label: badge.provider == .codex ? "X" : "C",
                            palette: palette,
                            metrics: metrics,
                            labelTint: blended(palette.edgeText, palette.text, amount: fusionProgress)
                        )
                    }
                }
            }
            if dockConflict {
                Image(systemName: "dock.arrow.up.rectangle")
                    .font(.system(size: 8))
                    .padding(.top, 5)
            }
        }
        .foregroundStyle(blended(palette.edgeText, palette.text, amount: fusionProgress).opacity(count == 0 ? 0.5 : 0.95))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: state.unreadCount) { newValue in
            guard newValue > 0, state.motionEnabled else { return }
            pulse = false
            withAnimation(.easeOut(duration: 0.7)) { pulse = true }
        }
    }
}

/// A cut gem whose colour bands the remaining quota and whose engraved number
/// carries the exact figure — colour answers "how tight", the digits answer
/// "how much". The number also keeps the reading available to colour-blind
/// users, which colour alone would not.
struct QuotaGem: View {
    enum Layout {
        /// Vertical tag: label sits under the stone.
        case stacked
        /// Horizontal strip: label leads the stone so both share one baseline.
        case inline
    }

    let percent: Double
    let label: String
    let palette: JianlingPalette
    let metrics: EdgeTagSize
    let labelTint: Color
    var layout: Layout = .stacked

    private var tier: QuotaTier { QuotaTier.tier(forRemainingPercent: percent) }
    private var stoneColor: Color { palette.quotaColor(tier) }

    var body: some View {
        Group {
            switch layout {
            case .stacked: VStack(spacing: 1.5) { stone; caption }
            case .inline: HStack(spacing: 3) { caption; stone }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label == "X" ? "Codex" : "Claude") \(Int(percent.rounded()))%")
    }

    private var caption: some View {
        Text(label)
            .font(.system(size: metrics.labelFontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(labelTint.opacity(0.45))
    }

    private var stone: some View {
        Group {
            ZStack {
                GemShape().fill(stoneColor)
                GemTopFacet().fill(.white.opacity(0.26))
                GemBottomFacet().fill(.black.opacity(0.20))
                GemShape().stroke(.white.opacity(0.16), lineWidth: 0.5)
                if tier == .critical {
                    // Second channel for the most urgent band so it does not
                    // rely on hue alone.
                    GemShape().stroke(.white.opacity(0.75), lineWidth: 0.9)
                }
                Text("\(Int(percent.rounded()))")
                    .font(.system(size: metrics.gemFontSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.black.opacity(0.66))
            }
            .frame(width: metrics.gemSize, height: metrics.gemSize)
        }
    }
}

struct QuotaBadgeData: Identifiable {
    let provider: QuotaProvider
    let remainingPercent: Double
    var id: String { provider.rawValue }
}

struct HostTrackingView: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        TrackingNSView(onChange: onChange)
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.onChange = onChange
    }

    final class TrackingNSView: NSView {
        var onChange: (Bool) -> Void
        private var tracking: NSTrackingArea?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let tracking = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .inVisibleRect, .activeAlways],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(tracking)
            self.tracking = tracking
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
    }
}
