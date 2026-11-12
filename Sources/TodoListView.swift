import SwiftUI
import AppKit

private struct TodoRowFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TodoGroupFramesKey: PreferenceKey {
    static var defaultValue: [Bool: CGRect] = [:]
    static func reduce(value: inout [Bool: CGRect], nextValue: () -> [Bool: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TodoDividerKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

private struct TodoTrailingInputTopKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

/// Fill the unused viewport without changing the measured task bodies used by drag.
/// The top offset is in content coordinates, so scrolling cannot inflate the input.
enum TodoBlankArea {
    static func height(viewport: CGFloat, inputTop: CGFloat?) -> CGFloat {
        guard let inputTop, inputTop.isFinite else { return PanelLayout.row }
        return max(PanelLayout.row, viewport - inputTop - 6)
    }
}

private struct TodoContentOriginKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A drop plan describes the visual placeholder and the single eventual mutation.
/// Completed rows always stay after unfinished rows, matching Store.section(later:).
struct TodoDropPlan: Equatable {
    var later: Bool
    var targetID: UUID?
    var above: Bool
    var indicatorY: CGFloat

    static func resolve(point: CGPoint, dragged: Todo, displayedItems: [Todo],
                        frames: [UUID: CGRect], groupFrames: [Bool: CGRect],
                        dividerY: CGFloat) -> TodoDropPlan? {
        guard dividerY.isFinite, dividerY != .greatestFiniteMagnitude else { return nil }
        let later = point.y >= dividerY
        return resolve(point: point, later: later, dragged: dragged,
                       displayedItems: displayedItems, frames: frames, groupFrames: groupFrames)
    }

    static func resolve(point: CGPoint, later: Bool, dragged: Todo, displayedItems: [Todo],
                        frames: [UUID: CGRect], groupFrames: [Bool: CGRect]) -> TodoDropPlan? {
        let destination = displayedItems.filter { $0.later == later && $0.id != dragged.id }
        let peers = destination.filter { $0.done == dragged.done }
        // All rows are measured (a regular VStack, not LazyVStack). Never offer a
        // guessed position if a layout pass has not supplied its frame yet.
        guard destination.allSatisfy({ frames[$0.id] != nil }) else { return nil }

        for item in peers {
            if let frame = frames[item.id], point.y < frame.midY {
                return TodoDropPlan(later: later, targetID: item.id, above: true,
                                    indicatorY: frame.minY)
            }
        }
        if let last = peers.last, let frame = frames[last.id] {
            return TodoDropPlan(later: later, targetID: last.id, above: false,
                                indicatorY: frame.maxY)
        }
        // A completed item cannot be inserted above unfinished items, and vice versa.
        if let boundary = dragged.done ? destination.last : destination.first,
           let frame = frames[boundary.id] {
            return TodoDropPlan(later: later, targetID: boundary.id, above: !dragged.done,
                                indicatorY: dragged.done ? frame.maxY : frame.minY)
        }
        guard let group = groupFrames[later] else { return nil }
        return TodoDropPlan(later: later, targetID: nil, above: false,
                            indicatorY: group.minY + (destination.isEmpty ? group.height / 2 : 0))
    }

    func apply(draggedID: UUID, store: Store) {
        guard changesDisplayedOrder(draggedID: draggedID,
            displayedItems: store.section(later: false) + store.section(later: true)) else { return }
        if let targetID {
            store.relocate(draggedID, relativeTo: targetID, above: above)
        } else {
            store.relocate(draggedID, toEndOf: later)
        }
    }

    func changesDisplayedOrder(draggedID: UUID, displayedItems: [Todo]) -> Bool {
        projectedItems(draggedID: draggedID, displayedItems: displayedItems) != displayedItems
    }

    func projectedItems(draggedID: UUID, displayedItems: [Todo]) -> [Todo] {
        guard var moving = displayedItems.first(where: { $0.id == draggedID }) else { return displayedItems }
        moving.later = later
        var projected = displayedItems.filter { $0.id != draggedID }
        if let targetID, let index = projected.firstIndex(where: { $0.id == targetID }) {
            projected.insert(moving, at: above ? index : index + 1)
        } else if let index = projected.lastIndex(where: { $0.later == later }) {
            projected.insert(moving, at: index + 1)
        } else {
            projected.append(moving)
        }
        return [false, true].flatMap { group in
            [false, true].flatMap { done in projected.filter { $0.later == group && $0.done == done } }
        }
    }
}

/// Stable layout captured before the first visual displacement. Neighbours animate
/// into these projected slots, while hit-testing never reads their animated frames.
struct TodoDragLayout {
    var items: [Todo]
    var frames: [UUID: CGRect]
    var groupFrames: [Bool: CGRect]
    var dividerY: CGFloat

    func projectedItems(draggedID: UUID, plan: TodoDropPlan?) -> [Todo] {
        plan?.projectedItems(draggedID: draggedID, displayedItems: items) ?? items
    }

    func bodyHeight(later: Bool, items: [Todo]) -> CGFloat {
        let rows = items.filter { $0.later == later }
        // The permanent input row is outside this measured task body, even when empty.
        return rows.reduce(0) { $0 + (frames[$1.id]?.height ?? PanelLayout.row) }
    }

    func nowHeightDelta(draggedID: UUID, plan: TodoDropPlan?) -> CGFloat {
        bodyHeight(later: false, items: projectedItems(draggedID: draggedID, plan: plan))
            - (groupFrames[false]?.height ?? 0)
    }

    func totalHeightDelta(draggedID: UUID, plan: TodoDropPlan?) -> CGFloat {
        let projected = projectedItems(draggedID: draggedID, plan: plan)
        return [false, true].reduce(CGFloat.zero) {
            $0 + bodyHeight(later: $1, items: projected) - (groupFrames[$1]?.height ?? 0)
        }
    }

    func inputOffset(later: Bool, draggedID: UUID, plan: TodoDropPlan?) -> CGFloat {
        let projected = projectedItems(draggedID: draggedID, plan: plan)
        let ownDelta = bodyHeight(later: later, items: projected) - (groupFrames[later]?.height ?? 0)
        return ownDelta + (later ? nowHeightDelta(draggedID: draggedID, plan: plan) : 0)
    }

    func projectedFrames(draggedID: UUID, plan: TodoDropPlan?) -> [UUID: CGRect] {
        let projected = projectedItems(draggedID: draggedID, plan: plan)
        let nowDelta = nowHeightDelta(draggedID: draggedID, plan: plan)
        var result: [UUID: CGRect] = [:]
        for later in [false, true] {
            guard let group = groupFrames[later] else { continue }
            var y = group.minY + (later ? nowDelta : 0)
            for item in projected where item.later == later {
                guard let frame = frames[item.id] else { continue }
                result[item.id] = CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height)
                y += frame.height
            }
        }
        return result
    }

    /// Group switching follows the divider currently visible on screen. Once a
    /// source group shrinks, its divider moves too; this creates a natural hysteresis
    /// band instead of oscillating between groups under a stationary pointer.
    func resolve(center: CGPoint, dragged: Todo, currentPlan: TodoDropPlan?) -> TodoDropPlan? {
        let currentDelta = nowHeightDelta(draggedID: dragged.id, plan: currentPlan)
        let later = center.y >= dividerY + currentDelta
        var moved = dragged
        moved.later = later
        let destinationItems = items.filter { $0.id != dragged.id } + [moved]
        let destinationDelta = bodyHeight(later: false, items: destinationItems)
            - (groupFrames[false]?.height ?? 0)
        // Only the whole group's origin moves here, never the animated peer offsets.
        let canonicalPoint = CGPoint(x: center.x, y: center.y - (later ? destinationDelta : 0))
        return TodoDropPlan.resolve(point: canonicalPoint, later: later, dragged: dragged,
            displayedItems: items, frames: frames, groupFrames: groupFrames)
    }
}

/// The snapshot frame and grab point never move with the row or with a reorder.
/// Pointer coordinates, row geometry, and the floating preview share the viewport.
struct TodoDragPosition {
    var originalFrame: CGRect
    var grabPoint: CGPoint

    func frame(at pointer: CGPoint) -> CGRect {
        CGRect(x: pointer.x - grabPoint.x, y: pointer.y - grabPoint.y,
               width: originalFrame.width, height: originalFrame.height)
    }
}

private struct TodoDragSession {
    var item: Todo
    var position: TodoDragPosition
    var pointer: CGPoint
    var originalItems: [Todo]
    var layout: TodoDragLayout
    var initialContentOrigin: CGFloat
    var plan: TodoDropPlan?
}

/// Editable list displayed inside the notch panel.
/// Dragging is visual-only; mouse release is the sole persistence point.
struct TodoListView: View {
    @ObservedObject var store: Store
    var editState: IslandState? = nil

    @StateObject private var editorSession = TodoEditorSession()
    @State private var coordinateID = UUID()
    @State private var contentCoordinateID = UUID()
    @State private var trailingInputTop: CGFloat?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var groupFrames: [Bool: CGRect] = [:]
    @State private var dividerY: CGFloat = .greatestFiniteMagnitude
    @State private var contentOrigin: CGFloat = 0
    @State private var drag: TodoDragSession?
    @State private var cancelledGesture = false

    private var displayedItems: [Todo] {
        store.section(later: false) + store.section(later: true)
    }

    private var nowHeightDelta: CGFloat {
        guard let drag else { return 0 }
        return drag.layout.nowHeightDelta(draggedID: drag.item.id, plan: drag.plan)
    }

    private var totalHeightDelta: CGFloat {
        guard let drag else { return 0 }
        return drag.layout.totalHeightDelta(draggedID: drag.item.id, plan: drag.plan)
    }

    var body: some View {
        let offsets = rowOffsets
        return GeometryReader { viewport in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    group(later: false, offsets: offsets)
                    Rectangle()
                        .fill(Color.primary.opacity(0.09))
                        .frame(height: 1)
                        .padding(.horizontal, PanelLayout.sidePadding)
                        .padding(.vertical, 7)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: TodoDividerKey.self,
                                value: geometry.frame(in: .named(coordinateID)).midY)
                        })
                        .offset(y: nowHeightDelta)
                        .animation(.interactiveSpring(response: 0.20, dampingFraction: 0.88), value: nowHeightDelta)
                    group(later: true, offsets: offsets,
                          minimumInputHeight: TodoBlankArea.height(viewport: viewport.size.height, inputTop: trailingInputTop))
                }
                .padding(.vertical, 6)
                .coordinateSpace(name: contentCoordinateID)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: TodoContentOriginKey.self,
                        value: geometry.frame(in: .named(coordinateID)).minY)
                })
                .padding(.bottom, totalHeightDelta)
            }
            .overlay(alignment: .topLeading) {
                if let drag {
                    let frame = drag.position.frame(at: drag.pointer)
                    TodoDragPreview(item: drag.item)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .coordinateSpace(name: coordinateID)
            .clipped()
            .onPreferenceChange(TodoRowFramesKey.self) { rowFrames = $0 }
            .onPreferenceChange(TodoGroupFramesKey.self) { groupFrames = $0 }
            .onPreferenceChange(TodoTrailingInputTopKey.self) { trailingInputTop = $0 }
            .onPreferenceChange(TodoDividerKey.self) { dividerY = $0 }
            .onPreferenceChange(TodoContentOriginKey.self) { origin in
                contentOrigin = origin
                updatePlanForCurrentPointer()
            }
            .onExitCommand { cancelActiveDrag() }
            .onDisappear { cancelActiveDrag() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                cancelActiveDrag()
            }
            // A day rollover or an external edit invalidates the snapshot safely.
            .onChange(of: store.items) { items in
                if let drag, items != drag.originalItems { cancelActiveDrag() }
            }
            .environment(\.todoDragViewportSize, viewport.size)
        }
    }

    private var projectedItems: [Todo] {
        guard let drag else { return displayedItems }
        return drag.layout.projectedItems(draggedID: drag.item.id, plan: drag.plan)
    }

    private var rowOffsets: [UUID: CGFloat] {
        guard let drag else { return [:] }
        let projected = drag.layout.projectedFrames(draggedID: drag.item.id, plan: drag.plan)
        return projected.reduce(into: [:]) { offsets, entry in
            guard entry.key != drag.item.id, let original = drag.layout.frames[entry.key] else { return }
            offsets[entry.key] = entry.value.minY - original.minY
        }
    }

    private func inputOffset(later: Bool) -> CGFloat {
        guard let drag else { return 0 }
        return drag.layout.inputOffset(later: later, draggedID: drag.item.id, plan: drag.plan)
    }

    private func group(later: Bool, offsets: [UUID: CGFloat],
                       minimumInputHeight: CGFloat = PanelLayout.row) -> some View {
        let items = store.section(later: later)
        return VStack(spacing: 0) {
            Text(later ? "稍后" : "现在")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.85))
                .padding(.horizontal, PanelLayout.sidePadding + 1)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: later ? nowHeightDelta : 0)
                .animation(.interactiveSpring(response: 0.20, dampingFraction: 0.88), value: nowHeightDelta)

            VStack(spacing: 0) {
                ForEach(items) { item in
                        TodoRowView(item: item, store: store, editState: editState, session: editorSession,
                                    coordinateID: coordinateID, isDragging: drag?.item.id == item.id,
                                    onDragChanged: { updateDrag(item: item, value: $0) },
                                    onDragEnded: { value, size in finishDrag(item: item, value: value, size: size) },
                                    onDragCancelled: { cancelDrag(id: item.id) })
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: TodoRowFramesKey.self,
                                    value: [item.id: geometry.frame(in: .named(coordinateID))])
                            })
                            .offset(y: offsets[item.id] ?? 0)
                            .animation(.interactiveSpring(response: 0.20, dampingFraction: 0.88), value: offsets[item.id] ?? 0)
                }
            }
            .frame(maxWidth: .infinity)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: TodoGroupFramesKey.self,
                    value: [later: geometry.frame(in: .named(coordinateID))])
            })

            InlineTodoInput(store: store, later: later, editState: editState, session: editorSession,
                            minimumHeight: minimumInputHeight)
                .frame(maxWidth: .infinity)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: TodoTrailingInputTopKey.self,
                        value: later ? geometry.frame(in: .named(contentCoordinateID)).minY : nil)
                })
                .offset(y: inputOffset(later: later))
                .animation(.interactiveSpring(response: 0.20, dampingFraction: 0.88), value: inputOffset(later: later))
                .allowsHitTesting(drag == nil)
        }
    }

    private func updateDrag(item: Todo, value: DragGesture.Value) {
        guard !cancelledGesture else { return }
        if drag == nil, let frame = rowFrames[item.id],
           groupFrames.count == 2, displayedItems.allSatisfy({ rowFrames[$0.id] != nil }) {
                drag = TodoDragSession(item: item,
                    position: TodoDragPosition(originalFrame: frame,
                        grabPoint: CGPoint(x: value.startLocation.x - frame.minX,
                                           y: value.startLocation.y - frame.minY)),
                    pointer: value.location, originalItems: store.items,
                    layout: TodoDragLayout(items: displayedItems, frames: rowFrames,
                                           groupFrames: groupFrames, dividerY: dividerY),
                    initialContentOrigin: contentOrigin, plan: nil)
        }
        guard drag?.item.id == item.id else { return }
        drag?.pointer = value.location
        updatePlanForCurrentPointer()
    }

    private func updatePlanForCurrentPointer() {
        guard let session = drag else { return }
        let frame = session.position.frame(at: session.pointer)
        let center = CGPoint(x: frame.midX,
                             y: frame.midY - (contentOrigin - session.initialContentOrigin))
        drag?.plan = session.layout.resolve(center: center, dragged: session.item, currentPlan: session.plan)
    }

    private func finishDrag(item: Todo, value: DragGesture.Value, size: CGSize) {
        defer { cancelledGesture = false }
        guard drag?.item.id == item.id else { return }
        drag?.pointer = value.location
        updatePlanForCurrentPointer()
        guard let session = drag else { return }
        guard contains(value.location, in: size), store.items == session.originalItems,
              let plan = session.plan else { cancelActiveDrag(); return }
        // Replace the visual projection with identical persisted layout in one
        // non-animated transaction, so neighbours do not animate back to old slots.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            drag = nil
            plan.apply(draggedID: item.id, store: store)
        }
    }

    private func cancelDrag(id: UUID) {
        if drag?.item.id == id { drag = nil }
        cancelledGesture = false
    }

    private func cancelActiveDrag() {
        if drag != nil { cancelledGesture = true }
        drag = nil
    }

    private func contains(_ point: CGPoint, in size: CGSize) -> Bool {
        point.x >= 0 && point.x <= size.width && point.y >= 0 && point.y <= size.height
    }
}

/// Shared by Enter, blur and multi-line paste; empty lines never become tasks.
enum TodoInputDraft {
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func replacingSelection(in text: String, range: NSRange, with pasted: String) -> String {
        let value = NSMutableString(string: text)
        let safeRange = range.location <= value.length && range.length <= value.length - range.location
            ? range : NSRange(location: value.length, length: 0)
        value.replaceCharacters(in: safeRange, with: pasted)
        return value as String
    }
}

enum TodoEditorTarget: Equatable {
    case task(UUID)
    case draft(Bool)
}

/// Explicit focus requests let Backspace move to the preceding task without
/// deleting that task's contents or relying on SwiftUI field-editor focus.
final class TodoEditorSession: ObservableObject {
    @Published var target: TodoEditorTarget?
    @Published var request = UUID()

    func focus(_ target: TodoEditorTarget) {
        self.target = target
        request = UUID()
    }

    func previous(before id: UUID?, later: Bool, store: Store) {
        let visible = store.section(later: false) + store.section(later: true)
        if let id, let index = visible.firstIndex(where: { $0.id == id }) {
            if index > 0 { focus(.task(visible[index - 1].id)) }
            else { focus(.draft(later)) }
        } else if let previous = store.section(later: later).last
                    ?? (later ? store.section(later: false).last : nil) {
            focus(.task(previous.id))
        }
    }
}

private func updateEditingState(_ active: Bool, window: NSWindow?,
                                later: Bool, state: IslandState?) {
    if active {
        state?.addToLater = later
        state?.editing = true
    } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak window, weak state] in
            state?.editing = (window?.firstResponder as? NSTextView)?.isEditable == true
        }
    }
}

/// The empty input and existing rows share the same AppKit keyboard implementation.
private struct InlineTodoInput: View {
    var store: Store
    var later: Bool
    var editState: IslandState?
    @ObservedObject var session: TodoEditorSession
    var minimumHeight: CGFloat = PanelLayout.row
    @State private var height: CGFloat = PanelLayout.row

    var body: some View {
        TodoNativeEditor(initialText: "", isDraft: true,
            accessibilityLabel: later ? "在稍后添加待办" : "在现在添加待办",
            inset: PanelLayout.sidePadding + 20.5,
            focusRequest: session.target == .draft(later) ? session.request : nil,
            onCommit: { text, _ in store.add(text, later: later) },
            onEmptyBackspace: { session.previous(before: nil, later: later, store: store) },
            onErased: {},
            onFocus: { active, window in
                updateEditingState(active, window: window, later: later, state: editState)
                if active {
                    DispatchQueue.main.async {
                        if session.target != .draft(later) { session.focus(.draft(later)) }
                    }
                }
            }, onHeight: { height = $0 })
            .frame(height: max(height, minimumHeight))
    }
}

private struct TodoNativeEditor: NSViewRepresentable {
    var initialText: String
    var isDraft: Bool
    var accessibilityLabel: String
    var inset: CGFloat
    var focusRequest: UUID?
    var onCommit: (String, Bool) -> Void
    var onEmptyBackspace: () -> Void
    var onErased: () -> Void
    var onFocus: (Bool, NSWindow?) -> Void
    var onHeight: (CGFloat) -> Void

    final class Coordinator { var focusRequest: UUID? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> InlineTodoInputScrollView {
        let view = InlineTodoInputScrollView()
        view.editor.string = initialText
        configure(view, context: context)
        return view
    }

    func updateNSView(_ view: InlineTodoInputScrollView, context: Context) {
        configure(view, context: context)
    }

    static func dismantleNSView(_ view: InlineTodoInputScrollView, coordinator: Coordinator) {
        // Resigning normally already saved the text. Defer the remaining save so
        // removing a SwiftUI row cannot recursively mutate its parent mid-update.
        view.editor.finishEditing()
    }

    private func configure(_ view: InlineTodoInputScrollView, context: Context) {
        let dark = context.environment.colorScheme == .dark
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.editor.selectedTextAttributes = [
            .backgroundColor: dark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.14),
            .foregroundColor: dark ? NSColor.white : NSColor.black
        ]
        view.editor.setAccessibilityLabel(accessibilityLabel)
        view.editor.textContainerInset = NSSize(width: inset, height: 5)
        view.editor.isDraft = isDraft
        view.editor.onCommit = onCommit
        view.editor.onEmptyBackspace = onEmptyBackspace
        view.editor.onErased = onErased
        view.editor.onFocus = onFocus
        view.onHeight = onHeight
        view.needsLayout = true
        view.requestEditorFocus(focusRequest)
    }
}

final class InlineTodoInputScrollView: NSScrollView {
    let editor = InlineTodoTextView(frame: NSRect(x: 0, y: 0, width: 1, height: 26))
    var onHeight: (CGFloat) -> Void = { _ in }
    private var reportedHeight: CGFloat = 26
    private var updatingLayout = false
    private var requestedFocus: UUID?
    private var appliedFocus: UUID?

    func requestEditorFocus(_ token: UUID?) {
        requestedFocus = token
        DispatchQueue.main.async { [weak self] in self?.applyPendingFocus() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.applyPendingFocus() }
    }

    private func applyPendingFocus() {
        guard let token = requestedFocus, token != appliedFocus, let window,
              window.makeFirstResponder(editor) else { return }
        appliedFocus = token
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        _ = scrollToVisible(bounds)
    }

    init() {
        super.init(frame: .zero)
        borderType = .noBorder
        focusRingType = .none
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.focusRingType = .none
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.font = .systemFont(ofSize: 12.5)
        editor.textContainerInset = NSSize(width: PanelLayout.sidePadding + 20.5, height: 5)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 26)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.onTextChanged = { [weak self] in self?.resizeEditor() }
        documentView = editor
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() { super.layout(); resizeEditor() }

    func resizeEditor() {
        guard !updatingLayout else { return }
        updatingLayout = true
        defer { updatingLayout = false }
        let width = max(contentSize.width, 1)
        let textWidth = max(1, width - editor.textContainerInset.width * 2)
        editor.textContainer?.containerSize = NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        var height: CGFloat = PanelLayout.row
        if let container = editor.textContainer, let manager = editor.layoutManager {
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            let lastLine = manager.extraLineFragmentRect
            height = max(PanelLayout.row, ceil(max(used.maxY, lastLine.maxY) + 10))
        }
        editor.minSize = NSSize(width: width, height: PanelLayout.row)
        // NSTextView must cover the full blank area, not just its first line.
        // Keep reportedHeight intrinsic so the filler cannot create a size loop.
        let size = NSSize(width: width, height: max(height, contentSize.height))
        if editor.frame.size != size { editor.setFrameSize(size) }
        if reportedHeight != height {
            reportedHeight = height
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reportedHeight == height else { return }
                self.onHeight(height)
            }
        }
    }
}

final class InlineTodoTextView: NSTextView {
    var onSubmit: ([String]) -> Void = { _ in } // Native regression-test compatibility.
    var onCommit: ((String, Bool) -> Void)?
    var onFocus: (Bool, NSWindow?) -> Void = { _, _ in }
    var onEmptyBackspace: () -> Void = {}
    var onErased: () -> Void = {}
    var onTextChanged: () -> Void = {}
    var isDraft = true
    private var finished = false
    private var interpretingMarkedKey = false
    private var lastSavedText: String?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // NSTextView normally excludes part of its text-container padding. A
        // blank task area should also accept clicks in that unused margin.
        guard !isHidden, alphaValue > 0,
              bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect, cursor: .iBeam)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { finished = false; onFocus(true, window) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { submitDraft(keepFocus: false); onFocus(false, window) }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        // Physical Return and keypad Enter are handled identically. Leave marked
        // text to the IME so confirming Chinese candidates never creates a task.
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
            if event.modifierFlags.contains(.shift) { insertSoftNewline() }
            else { submitDraft(keepFocus: true) }
            return
        }
        interpretingMarkedKey = hasMarkedText()
        defer { interpretingMarkedKey = false }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        let newline = ["insertNewline:", "insertNewlineIgnoringFieldEditor:"]
        if newline.contains(NSStringFromSelector(selector)) && !hasMarkedText() && !interpretingMarkedKey {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { insertSoftNewline() }
            else { submitDraft(keepFocus: true) }
        } else if selector == NSSelectorFromString("insertLineBreak:") && !hasMarkedText() && !interpretingMarkedKey {
            insertSoftNewline()
        } else if selector == NSSelectorFromString("cancelOperation:") && !hasMarkedText() && !interpretingMarkedKey {
            finished = true
            if isDraft { string = ""; onTextChanged() }
            window?.makeFirstResponder(nil)
            onFocus(false, window)
        } else {
            super.doCommand(by: selector)
        }
    }

    private func insertSoftNewline() {
        insertText("\n", replacementRange: selectedRange())
    }

    override func deleteBackward(_ sender: Any?) {
        if hasMarkedText() { super.deleteBackward(sender); return }
        if string.isEmpty {
            onEmptyBackspace()
            return
        }
        super.deleteBackward(sender)
        if string.isEmpty, !isDraft {
            finished = true
            onErased()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        lastSavedText = nil
        onTextChanged()
    }

    func submitDraft(keepFocus: Bool) {
        guard !finished else { return }
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDraft {
            string = ""
            setSelectedRange(NSRange(location: 0, length: 0))
            onTextChanged()
            if !text.isEmpty {
                if let onCommit { onCommit(text, keepFocus) }
                else { onSubmit([text]) }
            }
        } else if keepFocus || lastSavedText != text {
            lastSavedText = text
            onCommit?(text, keepFocus)
        }
        if keepFocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self, self.window?.firstResponder === self else { return }
                self.window?.contentView?.layoutSubtreeIfNeeded()
                if let input = self.enclosingScrollView { _ = input.scrollToVisible(input.bounds) }
            }
        }
    }

    func finishEditing() {
        guard !finished else { return }
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsSave = isDraft ? !text.isEmpty : lastSavedText != text
        let commit = onCommit
        let fallback = onSubmit
        finished = true
        if needsSave {
            DispatchQueue.main.async {
                if let commit { commit(text, false) }
                else if !text.isEmpty { fallback([text]) }
            }
        }
    }
}

private struct TodoDragViewportSizeKey: EnvironmentKey {
    static let defaultValue: CGSize = .zero
}

private extension EnvironmentValues {
    var todoDragViewportSize: CGSize {
        get { self[TodoDragViewportSizeKey.self] }
        set { self[TodoDragViewportSizeKey.self] = newValue }
    }
}

private struct TodoDragPreview: View {
    let item: Todo
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12.5))
                .foregroundStyle(item.done ? Color.primary : Color.secondary.opacity(0.55))
            TodoTitle(item: item)
        }
        .padding(.horizontal, PanelLayout.sidePadding)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: .black.opacity(0.20), radius: 5, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.45)))
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }
}

private struct TodoTitle: View {
    let item: Todo
    var body: some View {
        Text(item.title)
            .font(.system(size: 12.5))
            .strikethrough(item.done, color: .secondary)
            .foregroundStyle(item.done ? Color.secondary.opacity(0.55) : Color.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TodoRowView: View {
    let item: Todo
    @ObservedObject var store: Store
    var editState: IslandState?
    @ObservedObject var session: TodoEditorSession
    var coordinateID: UUID
    var isDragging: Bool
    var onDragChanged: (DragGesture.Value) -> Void
    var onDragEnded: (DragGesture.Value, CGSize) -> Void
    var onDragCancelled: () -> Void

    @Environment(\.todoDragViewportSize) private var viewportSize
    @State private var hovering = false
    @State private var editorHeight: CGFloat = PanelLayout.row
    @GestureState private var gestureActive = false
    private var editing: Bool { session.target == .task(item.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { store.toggle(item.id) }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(item.done ? Color.primary : Color.secondary.opacity(0.55))
                    .frame(height: PanelLayout.row)
            }
            .buttonStyle(.plain)
            .help(item.done ? "标记为未完成" : "完成")

            if editing {
                TodoNativeEditor(initialText: item.title, isDraft: false,
                    accessibilityLabel: "编辑待办", inset: 0, focusRequest: session.request,
                    onCommit: { text, advance in
                        store.update(item.id, title: text)
                        if advance { session.focus(.draft(item.later)) }
                    },
                    onEmptyBackspace: erase,
                    onErased: erase,
                    onFocus: { active, window in
                        updateEditingState(active, window: window, later: item.later, state: editState)
                        if !active {
                            DispatchQueue.main.async {
                                if session.target == .task(item.id) { session.target = nil }
                            }
                        }
                    }, onHeight: { editorHeight = $0 })
                    .frame(height: editorHeight)
            } else {
                TodoTitle(item: item)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture { if !isDragging { begin() } }
            }
        }
        .padding(.horizontal, PanelLayout.sidePadding)
        .frame(minHeight: PanelLayout.row)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(hovering && !editing ? Color.primary.opacity(0.05) : Color.clear)
            .padding(.horizontal, 10))
        .opacity(isDragging ? 0 : 1)
        .onHover { hovering = $0 }
        .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateID))
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { if !editing { onDragChanged($0) } }
            .onEnded { if !editing { onDragEnded($0, viewportSize) } })
        .onChange(of: gestureActive) { active in
            guard !active else { return }
            DispatchQueue.main.async { onDragCancelled() }
        }
        .contextMenu {
            Button("编辑", action: begin)
            Button("拷贝文字") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.title, forType: .string)
            }
            Button(item.later ? "移到现在" : "移到稍后") {
                store.relocate(item.id, toEndOf: !item.later)
            }
        }
    }

    private func begin() { session.focus(.task(item.id)) }

    private func erase() {
        session.previous(before: item.id, later: item.later, store: store)
        store.delete(item.id)
    }
}
