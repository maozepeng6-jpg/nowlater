import AppKit
import SwiftUI
import Combine

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        let editor = super.fieldEditor(createFlag, for: object)
        if let textView = editor as? NSTextView {
            textView.insertionPointColor = .lightGray
            textView.selectedTextAttributes = [.backgroundColor: NSColor.darkGray,
                                               .foregroundColor: NSColor.white]
        }
        return editor
    }
}

/// 非激活窗口也接收首个事件，由统一双击检测器决定是否切换开合。
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Local/global monitors share this gate, including clicks split across the
/// hardware notch and the small window hit area. A lone or right click never toggles.
struct NotchDoubleClickGate {
    enum Action { case none, open, collapse }
    private var previous: (time: TimeInterval, point: NSPoint)?
    private var lastEventTimestamp: TimeInterval?

    mutating func register(timestamp: TimeInterval, point: NSPoint, leftButton: Bool,
                           insideTrigger: Bool, interval: TimeInterval,
                           nativeClickCount: Int = 0) -> Bool {
        // Keep delivery deduplication across open/close resets. Otherwise the
        // same native double-click could open in one monitor and close in another.
        guard timestamp != lastEventTimestamp else { return false }
        lastEventTimestamp = timestamp
        guard leftButton, insideTrigger else { reset(); return false }
        // AppKit may deliver only the second click to this window (or an input
        // source may send one native double-click event). Trust that event only
        // after verifying the left button and the notch hit area above.
        if nativeClickCount == 2 {
            reset()
            return true
        }
        if let previous {
            let elapsed = timestamp - previous.time
            // Do not count a duplicate delivery of the same native event twice.
            if elapsed == 0 { return false }
            if elapsed > 0, elapsed <= interval,
               hypot(point.x - previous.point.x, point.y - previous.point.y) <= 8 {
                reset()
                return true
            }
        }
        previous = (timestamp, point)
        return false
    }

    mutating func action(timestamp: TimeInterval, point: NSPoint, leftButton: Bool,
                         insideTrigger: Bool, insideBody: Bool, wantsExpanded: Bool,
                         interval: TimeInterval, nativeClickCount: Int) -> Action {
        let doubleClick = register(timestamp: timestamp, point: point, leftButton: leftButton,
                                   insideTrigger: insideTrigger, interval: interval,
                                   nativeClickCount: nativeClickCount)
        // The notch takes precedence over the body/outside classification, even
        // when the first click has not yet completed a double-click gesture.
        if insideTrigger {
            return doubleClick ? (wantsExpanded ? .collapse : .open) : .none
        }
        return wantsExpanded && !insideBody ? .collapse : .none
    }

    mutating func reset() { previous = nil }
}

/// Visibility of content and the target window state are intentionally separate.
/// An outdated closing completion must never remove a newly reopened panel.
struct NotchPresentation {
    enum Phase { case collapsed, opening, expanded, closing }
    private(set) var phase: Phase = .collapsed
    private(set) var generation: UInt = 0

    var wantsExpanded: Bool { phase == .opening || phase == .expanded }
    var acceptsContentInteraction: Bool { phase == .expanded }
    var keepsContentMounted: Bool { phase != .collapsed }

    mutating func beginOpening() -> UInt? {
        guard !wantsExpanded else { return nil }
        generation &+= 1
        phase = .opening
        return generation
    }

    mutating func beginClosing() -> UInt? {
        guard wantsExpanded else { return nil }
        generation &+= 1
        phase = .closing
        return generation
    }

    mutating func complete(_ token: UInt, expanded: Bool) -> Bool {
        guard token == generation,
              phase == (expanded ? .opening : .closing) else { return false }
        phase = expanded ? .expanded : .collapsed
        return true
    }

    mutating func settle(expanded: Bool) {
        generation &+= 1
        phase = expanded ? .expanded : .collapsed
    }
}

/// Freeze SwiftUI's layout during opening/closing and reveal it by clipping the
/// window, instead of rewrapping every line into an increasingly narrow rectangle.
private final class NotchClipView: NSView {
    private var hostedView: NSView?
    private var frozenSize: NSSize?

    init(hosting: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 20
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        hosting.autoresizingMask = []
        addSubview(hosting)
        hostedView = hosting
    }

    required init?(coder: NSCoder) { nil }

    func freeze(at size: NSSize) {
        frozenSize = size
        layoutHostedView()
    }

    func unfreeze() {
        frozenSize = nil
        layoutHostedView()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutHostedView()
    }

    override func layout() {
        super.layout()
        layoutHostedView()
    }

    private func layoutHostedView() {
        let size = frozenSize ?? bounds.size
        let rect = NSRect(x: (bounds.width - size.width) / 2,
                          y: bounds.height - size.height, width: size.width, height: size.height)
        if hostedView?.frame != rect { hostedView?.frame = rect }
    }
}

/// 藏在刘海里的待办面板：双击切换开合，也可点别处平滑收回。
final class NotchController: NSObject, NSWindowDelegate {
    private let store: Store
    let state = IslandState()

    private let panel: IslandPanel
    private var hosting: ClickThroughHostingView<IslandView>!
    private var clippingView: NotchClipView!
    private var presentation = NotchPresentation()
    private var activationGate = NotchDoubleClickGate()

    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var globalClickMonitor: Any?
    private var openedAt = Date.distantPast

    private var resizeSession: PanelResizeSession?

    // 尺寸限制：最大就是默认的两倍
    private let minWidth: CGFloat = PanelLayout.width
    private var maxWidth: CGFloat { min(PanelLayout.width * 2, (targetScreen?.frame.width ?? 900) - 20) }

    init(store: Store) {
        self.store = store
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 180, height: 32)),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        super.init()
        setupPanel()
        setupMonitors()
        observe()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
    }

    // MARK: - Setup

    private func setupPanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        hosting = ClickThroughHostingView(rootView: IslandView(store: store,
                                                             state: state,
                                                             topInset: notchBand,
                                                             onOpenLog: { [weak self] in
                                                                 self?.showHistory()
                                                             }, onBack: { [weak self] in
                                                                 self?.showTasks()
                                                             }, onResize: { [weak self] edge, phase, point in
                                                                 self?.resize(edge: edge, phase: phase, point: point)
                                                             }))
        clippingView = NotchClipView(hosting: hosting)
        panel.contentView = clippingView
        panel.setFrame(collapsedFrame(), display: false)
        panel.orderFrontRegardless()

    }

    private func setupMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            guard self.presentation.wantsExpanded else { return nil }
            if event.keyCode == 53 {   // Esc
                if self.panel.attachedSheet != nil { return event }
                // 正在改待办或汇总文字时，Esc 交给输入框取消编辑。
                if self.state.editing { return event }
                if self.state.showingHistory { self.showTasks(); return nil }
                self.collapse()
                return nil
            }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "v" {
                return self.handlePaste(event)
            }
            return event
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            guard self.panel.attachedSheet == nil, self.resizeSession == nil else {
                self.activationGate.reset()
                return event
            }
            let point = self.screenPoint(for: event)
            self.handlePointerClick(event, point: point)
            guard event.window === self.panel else { return event }
            if self.hitTrigger(point) || !self.presentation.wantsExpanded { return nil }
            guard self.presentation.acceptsContentInteraction else { return nil }
            if !self.state.pinned {
                DispatchQueue.main.async { self.pin() }
            }
            return event
        }

        // 刘海那块系统不会把点击送进窗口，只能靠全局监听兜住
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            guard self.panel.attachedSheet == nil, self.resizeSession == nil else {
                self.activationGate.reset()
                return
            }
            #if INTERACTION_TEST
            if self.presentation.wantsExpanded { return }
            #endif
            let point = self.screenPoint(for: event)
            self.handlePointerClick(event, point: point)
        }
    }

    private func observe() {
        store.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.presentation.acceptsContentInteraction,
                      self.panel.attachedSheet == nil, self.resizeSession == nil else { return }
                self.animate(to: self.expandedFrame())
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let expanded = self.presentation.wantsExpanded
                self.presentation.settle(expanded: expanded)
                self.panel.setFrame(expanded ? self.expandedFrame() : self.collapsedFrame(), display: true)
                self.state.expanded = expanded
                self.clippingView.unfreeze()
            }
            .store(in: &cancellables)
    }

    // MARK: - Geometry

    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// 刘海那条带子的高度（含菜单栏）
    private var notchBand: CGFloat {
        max(targetScreen?.safeAreaInsets.top ?? 24, 24)
    }

    /// 刘海本体的宽度，左右各留 2pt，避免压到两侧的菜单栏项目
    private var notchWidth: CGFloat {
        guard let screen = targetScreen else { return 176 }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return max(right.minX - left.maxX - 4, 120)
        }
        return 176
    }

    /// 收起时：只覆盖刘海那块，完全透明，纯粹当点击感应区
    private func collapsedFrame() -> NSRect {
        guard let screen = targetScreen else { return .zero }
        let w = notchWidth
        let h = notchBand
        return NSRect(x: screen.frame.midX - w / 2,
                      y: screen.frame.maxY - h,
                      width: w,
                      height: h)
    }

    private func currentWidth() -> CGFloat {
        min(max(state.width, minWidth), maxWidth)
    }

    /// 按条目数算出来的"刚好放得下"的高度
    private func autoContentHeight() -> CGFloat {
        if state.showingHistory { return 400 }
        return PanelLayout.height(now: store.section(later: false),
                           later: store.section(later: true),
                           width: currentWidth())
    }

    private func maxContentHeight() -> CGFloat {
        let screenH = targetScreen?.frame.height ?? 900
        return screenH - notchBand - 40
    }

    private func resolvedContentHeight() -> CGFloat {
        let base = autoContentHeight()
        guard state.manualHeight > 0 else { return min(base, maxContentHeight()) }
        return min(max(state.manualHeight, 178), maxContentHeight())
    }

    /// 展开时：从屏幕最顶边开始画，卡片和刘海连成一整块，内容再往下让出刘海的高度
    private func expandedFrame() -> NSRect {
        guard let screen = targetScreen else { return .zero }
        let w = currentWidth()
        let h = notchBand + resolvedContentHeight()
        return NSRect(x: screen.frame.midX - w / 2,
                      y: screen.frame.maxY - h,
                      width: w,
                      height: h)
    }

    private func resize(edge: PanelResizeEdge, phase: PanelResizePhase, point: NSPoint) {
        guard presentation.acceptsContentInteraction, panel.attachedSheet == nil else { return }
        if phase == .began {
            resizeSession = PanelResizeSession(edge: edge, startPointer: point, startFrame: panel.frame)
        }
        guard let session = resizeSession else { return }
        let frame = session.frame(at: point, minWidth: minWidth, maxWidth: maxWidth,
                                  minHeight: notchBand + 178, maxHeight: notchBand + maxContentHeight())
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.width = frame.width
            // 固定当前总高，改变宽度时不因文本换行让下边缘跳动。
            state.manualHeight = frame.height - notchBand
            panel.setFrame(frame, display: true)
            hosting.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
        }
        if phase == .ended {
            resizeSession = nil
            state.persistSize()
        }
    }

    func showHistory() {
        state.editing = false
        panel.makeFirstResponder(nil)
        state.showingHistory = true
        if presentation.acceptsContentInteraction { animate(to: expandedFrame()); focusPanel() }
        else { open() }
    }

    func showTasks() {
        guard panel.attachedSheet == nil else { return }
        state.showingHistory = false
        if presentation.acceptsContentInteraction { animate(to: expandedFrame()); focusPanel() }
        else { open() }
    }

    // MARK: - Hit areas

    /// 触发区：刘海本体 + 四周留一点容差。
    /// 关键：屏幕最顶上那一像素正好等于 rect.maxY，而 NSRect.contains 用的是半开区间，
    /// 会把"贴着最上边缘点"判成 false —— 这就是之前点最上面没反应的原因，这里改成闭区间。
    private var triggerRect: NSRect {
        let base = collapsedFrame()
        return NSRect(x: base.minX - 10,
                      y: base.minY - 10,
                      width: base.width + 20,
                      height: base.height + 10)
    }

    private func hitTrigger(_ p: NSPoint) -> Bool {
        let r = triggerRect
        return p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
    }

    /// 卡片正文（不含刘海那条带子）
    private func hitBody(_ p: NSPoint) -> Bool {
        let f = panel.frame
        let r = NSRect(x: f.minX - 1, y: f.minY, width: f.width + 2, height: f.height - notchBand + 1)
        return p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
    }

    private func handlePointerClick(_ event: NSEvent, point: NSPoint) {
        switch activationGate.action(timestamp: event.timestamp, point: point,
                                     leftButton: event.type == .leftMouseDown,
                                     insideTrigger: hitTrigger(point), insideBody: hitBody(point),
                                     wantsExpanded: presentation.wantsExpanded,
                                     interval: NSEvent.doubleClickInterval,
                                     nativeClickCount: event.clickCount) {
        case .open: open()
        case .collapse: collapse()
        case .none: break
        }
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        // Event coordinates also work for virtual input; the physical mouse may
        // be somewhere else. Global hardware-notch events have no window.
        guard let window = event.window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    // MARK: - State changes

    /// Keep confirmation attached to the island so clicking its buttons cannot
    /// collapse the parent panel or place a dialog behind the status-bar window.
    @discardableResult
    func presentQuitConfirmation(_ alert: NSAlert,
                                 completion: @escaping (NSApplication.ModalResponse) -> Void) -> Bool {
        guard panel.attachedSheet == nil, resizeSession == nil else { return false }
        if !presentation.acceptsContentInteraction {
            presentation.settle(expanded: true)
            state.expanded = true
            state.pinned = true
            clippingView.unfreeze()
            panel.setFrame(expandedFrame(), display: true)
            hosting.layoutSubtreeIfNeeded()
        }
        activationGate.reset()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: panel) { [weak self] response in
            completion(response)
            if response != .alertFirstButtonReturn, let self {
                self.animate(to: self.expandedFrame())
                self.focusPanel()
            }
        }
        return true
    }

    func open() {
        guard let token = presentation.beginOpening() else { return }
        activationGate.reset()
        let destination = expandedFrame()
        // Give SwiftUI its final layout before the narrow window reveals it.
        clippingView.freeze(at: destination.size)
        state.editing = false
        state.expanded = presentation.keepsContentMounted
        state.pinned = true
        openedAt = Date()
        hosting.layoutSubtreeIfNeeded()
        animate(to: destination, duration: 0.24) { [weak self] in
            guard let self, self.presentation.complete(token, expanded: true) else { return }
            self.clippingView.unfreeze()
            // Edits or a page change arriving during the animation may affect height.
            let resolved = self.expandedFrame()
            if self.panel.frame != resolved { self.animate(to: resolved) }
        }
        focusPanel()
    }

    func pin() {
        state.pinned = true
        focusPanel()
    }

    private func focusPanel() {
        guard panel.attachedSheet == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.presentation.wantsExpanded,
                  self.panel.attachedSheet == nil, !self.panel.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
        }
    }

    func collapse() {
        guard panel.attachedSheet == nil, let token = presentation.beginClosing() else { return }
        activationGate.reset()
        resizeSession = nil
        state.pinned = false
        panel.makeFirstResponder(nil)
        state.editing = false
        // Keep the content mounted and at its current full size until the window
        // has visibly returned to the notch. Removing it first caused the flash.
        clippingView.freeze(at: hosting.bounds.size)
        animate(to: collapsedFrame(), duration: 0.26) { [weak self] in
            guard let self, self.presentation.complete(token, expanded: false) else { return }
            self.state.expanded = self.presentation.keepsContentMounted
            self.clippingView.unfreeze()
        }
    }

    private func animate(to rect: NSRect, duration: TimeInterval = 0.18,
                         completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.3, 1.0)
            panel.animator().setFrame(rect, display: true)
        }, completionHandler: completion)
    }

    // MARK: - Clipboard

    /// 多行粘贴：一行一条，批量加进当前分组。返回 true 表示已消费这次粘贴
    func trySmartPaste() -> Bool {
        // 正在输入时让文本控件接收粘贴；不要把编辑中的文字误当新任务。
        if panel.firstResponder is NSTextView || panel.firstResponder is NSTextField { return false }
        guard panel.isKeyWindow, presentation.acceptsContentInteraction, !state.showingHistory,
              let raw = NSPasteboard.general.string(forType: .string)
        else { return false }

        let lines = raw
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count > 1 else { return false }
        for line in lines {
            store.add(line, later: state.addToLater)
        }
        return true
    }

    private func handlePaste(_ event: NSEvent) -> NSEvent? {
        let raw = NSPasteboard.general.string(forType: .string)
        let isMultiLine = raw?.contains(where: { $0 == "\n" || $0 == "\r" }) ?? false
        guard isMultiLine else { return event }
        return trySmartPaste() ? nil : event
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        #if !INTERACTION_TEST
        // 刚展开的一瞬间可能被系统抢一次 key，忽略掉
        guard presentation.wantsExpanded, panel.attachedSheet == nil, resizeSession == nil,
              Date().timeIntervalSince(openedAt) > 0.4 else { return }
        // A physical-notch mouse-down can transfer focus before the global
        // monitor receives it. Let that gesture finish rather than closing on
        // its first click. Pointer position alone must not suppress Command-Tab.
        if NSEvent.pressedMouseButtons != 0, hitTrigger(NSEvent.mouseLocation) { return }
        collapse()
        #endif
    }
}
