import Foundation
import AppKit
import SwiftUI

@main
struct TodoDragTests {
    static func main() throws {
        setbuf(stdout, nil)
        
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        func point(_ y: CGFloat, _ x: CGFloat = 70) -> CGPoint { CGPoint(x: x, y: y) }
        let a = Todo(title: "Now A")
        let b = Todo(title: "Now B, wrapped line")
        let c = Todo(title: "Now done", done: true)
        let d = Todo(title: "Later A", later: true)
        let e = Todo(title: "Later done", later: true, done: true)
        let rows = [a, b, c, d, e]
        let frames: [UUID:CGRect] = [a.id: CGRect(x:0,y:20,width:320,height:26),
         b.id: CGRect(x:0,y:46,width:320,height:42), c.id: CGRect(x:0,y:88,width:320,height:26),
         d.id: CGRect(x:0,y:145,width:320,height:26), e.id: CGRect(x:0,y:171,width:320,height:26)]
        let groups = [false:CGRect(x:0,y:20,width:320,height:94), true:CGRect(x:0,y:145,width:320,height:52)]
        func resolve(_ item: Todo, _ y: CGFloat) -> TodoDropPlan {
            TodoDropPlan.resolve(point:point(y), dragged:item, displayedItems:rows,
                frames:frames, groupFrames:groups, dividerY:130)!
        }
        let start = TodoDragPosition(originalFrame:frames[b.id]!, grabPoint:CGPoint(x:11,y:7))
        let initialPointer = CGPoint(x:11,y:53)
        for dy in stride(from: -150.0, through: 350.0, by: 0.5) {
            let cursor = CGPoint(x:initialPointer.x+23.5,y:initialPointer.y+dy)
            let f = start.frame(at:cursor)
            expect(abs(f.minY - frames[b.id]!.minY - dy) < 0.00001, "Drag is not 1:1")
            expect(f.minX == 23.5 && f.height == 42, "Grab anchor or height changed")
        }
        let beforeWrapped = resolve(a, 66)
        expect(beforeWrapped.targetID == b.id && beforeWrapped.above && beforeWrapped.indicatorY == 46, "Wrapped-row top half")
        let afterWrapped = resolve(a, 68)
        expect(afterWrapped.targetID == b.id && !afterWrapped.above && afterWrapped.indicatorY == 88, "Wrapped-row bottom half")
        let down = resolve(a, 120)
        expect(down.targetID == b.id && down.indicatorY == 88, "Unfinished item must stay above completed")
        let completedUp = resolve(c, 20)
        expect(completedUp.targetID == b.id && !completedUp.above && completedUp.indicatorY == 88, "Completed must stay at group end")
        let across = resolve(a, 132)
        expect(across.later && across.targetID == d.id && across.above, "Cross-divider drop")
        expect(resolve(a,129).later == false, "Divider threshold")
        expect(!resolve(b,68).changesDisplayedOrder(draggedID:b.id,displayedItems:rows), "No-op move should not save")
        let scrollOffset:CGFloat = 40
        let scrolled = TodoDropPlan.resolve(point:point(132-scrollOffset),dragged:a,displayedItems:rows,
         frames:frames.mapValues { $0.offsetBy(dx:0,dy:-scrollOffset) },
         groupFrames:groups.mapValues { $0.offsetBy(dx:0,dy:-scrollOffset) },dividerY:130-scrollOffset)!
        expect(scrolled.targetID == across.targetID && scrolled.above == across.above && scrolled.later,
         "Scrolling changes destination despite stable viewport coordinates")
        let emptyLater = TodoDropPlan.resolve(point:point(155),dragged:b,displayedItems:[a,b,c],
         frames:frames,groupFrames:[false:groups[false]!,true:CGRect(x:0,y:145,width:320,height:0)],dividerY:130)!
        expect(emptyLater.later && emptyLater.targetID == nil && emptyLater.indicatorY == 145, "Empty group target")
        let noIncomplete = TodoDropPlan.resolve(point:point(195),dragged:a,displayedItems:[a,b,c,e],
         frames:frames,groupFrames:groups,dividerY:130)!
        expect(noIncomplete.targetID == e.id && noIncomplete.above && noIncomplete.indicatorY == 171,
         "Unfinished entering completed-only group")
        let noCompleted = TodoDropPlan.resolve(point:point(132),dragged:c,displayedItems:[a,b,c,d],
         frames:frames,groupFrames:groups,dividerY:130)!
        expect(noCompleted.targetID == d.id && !noCompleted.above && noCompleted.indicatorY == 171,
         "Completed entering unfinished-only group")
        expect(TodoDropPlan.resolve(point:point(100),dragged:a,displayedItems:rows,frames:[:],
         groupFrames:groups,dividerY:130) == nil, "Missing frames should not guess a target")
        
        // Store is isolated under a required temporary root; never use the normal app data.
        guard let root = ProcessInfo.processInfo.environment["NOWLATER_HOME"], root.contains("/nowlater-interaction-tests.") else {
            fatalError("Missing isolated test directory")
        }
        let layout = TodoDragLayout(items: rows, frames: frames, groupFrames: groups, dividerY: 130)
        let bAboveA = layout.resolve(center: point(20), dragged: b, currentPlan: nil)!
        let bAboveFrames = layout.projectedFrames(draggedID: b.id, plan: bAboveA)
        expect(bAboveFrames[b.id]!.minY == 20 && bAboveFrames[a.id]!.minY == 62,
               "A must give way by B's full wrapped-row height while B occupies its old slot")
        expect(bAboveFrames[c.id] == frames[c.id], "Unaffected neighbour moved")
        let bReturned = layout.resolve(center: point(67), dragged: b, currentPlan: bAboveA)!
        expect(!bReturned.changesDisplayedOrder(draggedID: b.id, displayedItems: rows),
               "Dragging back must restore the original order")
        expect(layout.projectedFrames(draggedID: b.id, plan: nil) == frames,
               "Cancelling the projection must restore every original frame")
        let aBelowB = layout.resolve(center: point(80), dragged: a, currentPlan: nil)!
        let aBelowFrames = layout.projectedFrames(draggedID: a.id, plan: aBelowB)
        expect(aBelowFrames[b.id]!.minY == 20 && aBelowFrames[a.id]!.minY == 62,
               "Dragging down must move B upward without overlap")
        var livePlan = layout.resolve(center: point(131), dragged: b, currentPlan: nil)!
        expect(livePlan.later, "Cross-group preview did not switch to Later")
        let stablePlan = livePlan
        for _ in 0..<1000 {
            livePlan = layout.resolve(center: point(131), dragged: b, currentPlan: livePlan)!
            expect(livePlan == stablePlan, "Stationary cursor causes cross-group oscillation")
        }
        expect(layout.nowHeightDelta(draggedID: b.id, plan: livePlan) == -42,
               "Now heading/body did not shrink by the moved row height")
        livePlan = layout.resolve(center: point(100), dragged: b, currentPlan: livePlan)!
        expect(livePlan.later, "Cross-group hysteresis must use the visible divider")
        livePlan = layout.resolve(center: point(87), dragged: b, currentPlan: livePlan)!
        expect(!livePlan.later, "Dragging above the visible divider must return to Now")
        for _ in 0..<1000 {
            livePlan = layout.resolve(center: point(87), dragged: b, currentPlan: livePlan)!
            expect(!livePlan.later, "Returning to Now must not oscillate")
        }
        var reversePlan = layout.resolve(center: point(129), dragged: d, currentPlan: nil)!
        expect(!reversePlan.later && layout.nowHeightDelta(draggedID: d.id, plan: reversePlan) == 26,
               "Later-to-Now must expand the first group")
        for _ in 0..<1000 {
            reversePlan = layout.resolve(center: point(129), dragged: d, currentPlan: reversePlan)!
            expect(!reversePlan.later, "Reverse crossing oscillated")
        }
        reversePlan = layout.resolve(center: point(157), dragged: d, currentPlan: reversePlan)!
        expect(reversePlan.later, "Dragging back below the expanded divider did not return to Later")
        // Project every row through many positions, including completed-row constraints.
        for item in rows {
            var plan: TodoDropPlan?
            for y in stride(from: -20.0, through: 260.0, by: 2) {
                plan = layout.resolve(center: point(y), dragged: item, currentPlan: plan)
                let ordered = layout.projectedItems(draggedID: item.id, plan: plan)
                let projected = layout.projectedFrames(draggedID: item.id, plan: plan)
                for later in [false, true] {
                    let group = ordered.filter { $0.later == later }
                    for (first, second) in zip(group, group.dropFirst()) {
                        expect(projected[first.id]!.maxY == projected[second.id]!.minY,
                               "Projected rows overlap or leave a false gap")
                        expect(!first.done || second.done, "Completed row appeared above unfinished row")
                    }
                }
            }
        }
        let emptyLayout = TodoDragLayout(items: [a,b,c], frames: frames,
            groupFrames: [false:groups[false]!,true:CGRect(x:0,y:145,width:320,height:0)], dividerY:130)
        let toEmpty = emptyLayout.resolve(center: point(155), dragged:b, currentPlan:nil)!
        expect(toEmpty.later && toEmpty.targetID == nil, "Live preview cannot enter an empty group")
        expect(emptyLayout.totalHeightDelta(draggedID:b.id,plan:toEmpty) == 0,
               "The permanent input rows must not add or remove height during a cross-group move")
        let oneRowLayout = TodoDragLayout(items:[b,d],
            frames:[b.id:CGRect(x:0,y:20,width:320,height:42),d.id:CGRect(x:0,y:93,width:320,height:26)],
            groupFrames:[false:CGRect(x:0,y:20,width:320,height:42),true:CGRect(x:0,y:93,width:320,height:26)],
            dividerY:78)
        let leavingEmpty = oneRowLayout.resolve(center:point(120),dragged:b,currentPlan:nil)!
        expect(oneRowLayout.nowHeightDelta(draggedID:b.id,plan:leavingEmpty) == -42,
               "An empty task body must have zero height independently of its input row")
        expect(oneRowLayout.totalHeightDelta(draggedID:b.id,plan:leavingEmpty) == 0,
               "Both fixed input rows must remain while a source becomes empty")
        
        expect(emptyLayout.inputOffset(later:false,draggedID:b.id,plan:toEmpty) == -42,
               "The Now blank input row must follow its new task tail")
        expect(emptyLayout.inputOffset(later:true,draggedID:b.id,plan:toEmpty) == 0,
               "The Later blank input row must stay below all tasks")
        expect(emptyLayout.projectedFrames(draggedID:b.id,plan:toEmpty).count == 3,
               "Blank input rows must never appear as draggable task frames")
        expect(TodoInputDraft.lines("  \n \r\n ") == [], "An empty input must not create a task")
        expect(TodoInputDraft.lines("  第一条\r\n\r\n第二条  \n第三条") == ["第一条","第二条","第三条"],
               "Multi-line paste must preserve task order and ignore blank lines")
        let pasted = TodoInputDraft.replacingSelection(in:"前缀待替换后缀",range:NSRange(location:2,length:3),with:"甲\n乙")
        expect(TodoInputDraft.lines(pasted) == ["前缀甲","乙后缀"], "Paste must replace selection without losing the draft")
        let unicodePaste = TodoInputDraft.replacingSelection(in:"😀事项",range:NSRange(location:2,length:0),with:"新的\n")
        expect(TodoInputDraft.lines(unicodePaste) == ["😀新的","事项"], "Unicode UTF-16 paste range must remain correct")

        let store = Store()
        store.items = rows
        store.toggle(a.id)
        store.toggle(a.id)
        let tasksURL = URL(fileURLWithPath:root).appendingPathComponent("NowLater/tasks.json")
        let saved = try Data(contentsOf:tasksURL)
        for _ in 0..<1000 {
            let preview = layout.resolve(center:point(20),dragged:b,currentPlan:nil)
            _ = layout.projectedFrames(draggedID:b.id,plan:preview)
        }
        expect(store.items == rows && (try! Data(contentsOf:tasksURL)) == saved, "Hover preview changed data")
        // Test the exact public Store mutations used after release, including persistence.
        across.apply(draggedID:a.id,store:store)
        expect(store.section(later:false).map(\.id) == [b.id,c.id], "Cross-group source")
        expect(store.section(later:true).map(\.id) == [a.id,d.id,e.id], "Cross-group destination")
        expect(store.items.first(where:{$0.id == a.id})!.done == false, "Done status changed")
        let reloaded = Store()
        expect(reloaded.section(later:true).map(\.id) == [a.id,d.id,e.id], "Order not persisted")
        store.items = rows
        noCompleted.apply(draggedID:c.id,store:store)
        expect(store.section(later:true).map(\.id) == [d.id,c.id,e.id], "Completed target differs from indicator")
        let expected = bAboveA.projectedItems(draggedID:b.id,displayedItems:rows)
        store.items = rows
        bAboveA.apply(draggedID:b.id,store:store)
        expect(store.section(later:false) + store.section(later:true) == expected,
               "Committed order differs from the preview the user saw")
        // Exercise the actual AppKit blank row. Pure layout arithmetic missed
        // the NSTextView zero-height regression in 1.0.2.
        _ = NSApplication.shared
        for later in [false, true] {
            let input = InlineTodoInputScrollView()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 26),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = input
            for width: CGFloat in [320, 640, 300] {
                input.setFrameSize(NSSize(width: width, height: 26))
                input.needsLayout = true
                input.layoutSubtreeIfNeeded()
                expect(input.editor.frame.height == 26, "Blank native editor has no clickable height")
                expect(input.editor.frame.width >= width, "Blank editor does not fill the row")
                let hit = input.hitTest(NSPoint(x: width / 2, y: 13))
                expect(hit === input.editor || hit?.isDescendant(of: input.editor) == true,
                       "Blank-row click misses the actual text editor")
            }
            expect(input.acceptsFirstMouse(for: nil) && input.editor.acceptsFirstMouse(for: nil),
                   "Blank input must accept the first click in the panel")
            var submitted = 0
            // Wire the editor exactly like InlineTodoInput does: Enter materializes
            // a blank circle row immediately, blur only saves non-empty text.
            input.editor.onCommit = { text, advance in
                submitted += 1
                store.add(text, later: later)
                if advance { store.addBlank(later: later) }
            }
            expect(window.makeFirstResponder(input.editor), "Native input cannot obtain focus")
            for title in ["新增第一项", "连续输入第二项"] {
                input.editor.insertText(title, replacementRange: NSRange(location: NSNotFound, length: 0))
                input.editor.doCommand(by: NSSelectorFromString("insertNewline:"))
                expect(input.editor.string.isEmpty, "Enter did not leave a fresh blank row")
                expect(store.items.contains { $0.title == title && $0.later == later }, "Entered task was not saved in its group")
            }
            input.editor.doCommand(by: NSSelectorFromString("insertNewline:"))
            expect(submitted == 3, "Blank Enter must also reach the composer")
            expect(store.section(later: later).filter { $0.title.isEmpty }.count == 3,
                   "Each Enter must materialize an empty circle row")
            input.editor.insertText("失焦保存", replacementRange: NSRange(location: NSNotFound, length: 0))
            window.makeFirstResponder(nil)
            expect(submitted == 4, "Blur did not save the typed draft exactly once")
            expect(store.section(later: later).filter { $0.title.isEmpty }.count == 3,
                   "Blur must not spawn an extra blank row")
            expect(!window.isVisible, "Headless input regression opened a test window")
        }
        // Exercise real key events as well as doCommand; the two native paths
        // differed in older builds. No global keyboard events or visible windows.
        let keyboardInput = InlineTodoInputScrollView()
        let keyboardWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                                       styleMask: .borderless, backing: .buffered, defer: false)
        keyboardWindow.isReleasedWhenClosed = false
        keyboardWindow.contentView = keyboardInput
        keyboardInput.setFrameSize(NSSize(width: 320, height: 100))
        keyboardInput.layoutSubtreeIfNeeded()
        keyboardWindow.makeFirstResponder(keyboardInput.editor)
        let editor = keyboardInput.editor
        func returnEvent(_ flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 36) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 1, windowNumber: keyboardWindow.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: keyCode)!
        }
        var values: [String] = []
        editor.onSubmit = { values.append(contentsOf: $0) }
        editor.insertText("第一行", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: returnEvent(.shift))
        editor.insertText("第二行", replacementRange: NSRange(location: NSNotFound, length: 0))
        expect(values.isEmpty && editor.string == "第一行\n第二行", "Shift+Return must insert a newline without adding a task")
        expect(editor.frame.height > PanelLayout.row, "Multiline native editor did not grow")
        editor.keyDown(with: returnEvent())
        expect(values == ["第一行\n第二行"] && editor.string.isEmpty, "Physical Return must add exactly one multiline task")
        editor.insertText("数字键盘", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: returnEvent(keyCode: 76))
        expect(values.last == "数字键盘" && values.count == 2, "Keypad Enter did not submit")
        editor.setMarkedText("拼音候选", selectedRange: NSRange(location: 4, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let beforeIME = values.count
        editor.keyDown(with: returnEvent())
        expect(values.count == beforeIME, "Return confirming marked IME text must not create a task")
        editor.unmarkText()
        editor.string = ""
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        var previousRequests = 0
        editor.onEmptyBackspace = { previousRequests += 1 }
        editor.deleteBackward(nil)
        expect(previousRequests == 1 && values.count == 2, "Blank Backspace must request previous row without creating or deleting data")

        editor.isDraft = false
        editor.string = "甲乙😀"
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        var erased = 0
        var advances = 0
        var committed = ""
        editor.onErased = { erased += 1 }
        editor.onCommit = { text, advance in committed = text; if advance { advances += 1 } }
        editor.deleteBackward(nil)
        expect(editor.string == "甲乙" && erased == 0, "Backspace must delete one Unicode character, not the previous task")
        editor.deleteBackward(nil)
        expect(editor.string == "甲" && erased == 0, "Backspace removed task before its text became empty")
        editor.keyDown(with: returnEvent(.shift))
        editor.insertText("后续", replacementRange: NSRange(location: NSNotFound, length: 0))
        expect(advances == 0 && editor.string == "甲\n后续", "Existing row Shift+Return must remain inside the task")
        editor.keyDown(with: returnEvent())
        expect(advances == 1 && committed == "甲\n后续", "Existing row Return must save and request a new task")
        editor.string = "终"
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.deleteBackward(nil)
        expect(erased == 1 && editor.string.isEmpty, "Deleting the final character must remove the empty task and its circle")

        let session = TodoEditorSession()
        let first = Todo(title: "前一个", later: false)
        let second = Todo(title: "后一个", later: false)
        store.items = [first, second]
        session.previous(before: nil, later: false, store: store)
        expect(session.target == .task(second.id), "Empty now input must return to last now task")
        session.previous(before: second.id, later: false, store: store)
        expect(session.target == .task(first.id), "Erased row must focus previous task")
        session.previous(before: first.id, later: false, store: store)
        expect(session.target == .draft(false), "Deleting the first task must leave an editable empty row")
        session.previous(before: nil, later: true, store: store)
        expect(session.target == .task(second.id), "Empty later group must allow Backspace into previous group")
        expect(PanelLayout.rowHeight("一\n二\n三", width: 320) > PanelLayout.row * 2,
               "Panel height ignored explicit line breaks")
        expect(!keyboardWindow.isVisible, "Keyboard regression test opened a visible window")
        print("PASS: actual Return/keypad Enter; Shift+Return retains multiline task in both input modes; empty-row focus traversal; character-by-character Unicode deletion and empty-circle removal; multiline layout.")
        let savedInput = Store()
        expect(savedInput.items.filter { $0.title == "连续输入第二项" }.count == 2,
               "Native-input tasks did not survive reloading from disk")

        // Blank rows: Enter materializes empty circle rows; an empty commit keeps
        // the row (only Backspace on an empty row removes it); insertBlank lands
        // directly below the source row.
        let blankStore = Store()
        blankStore.items = []
        let firstBlank = blankStore.addBlank(later: false)
        expect(blankStore.items.count == 1 && firstBlank.title.isEmpty,
               "addBlank must create exactly one empty row")
        blankStore.update(firstBlank.id, title: "")
        expect(blankStore.items.count == 1, "Empty commit must not delete the blank row")
        guard let belowBlank = blankStore.insertBlank(after: firstBlank.id) else {
            expect(false, "insertBlank(after:) returned nil")
            return
        }
        expect(blankStore.items.map(\.id) == [firstBlank.id, belowBlank.id],
               "insertBlank must land directly below the source row")
        blankStore.update(firstBlank.id, title: "补字")
        expect(blankStore.items.first?.title == "补字", "Typing into a blank row must save its text")
        // Instantiate the real SwiftUI list offscreen, including its geometry
        // preferences and the native scroll editors. No desktop event injection.
        store.items = []
        let host = NSHostingView(rootView: TodoListView(store: store))
        let areaWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 430),
                                  styleMask: .borderless, backing: .buffered, defer: false)
        areaWindow.isReleasedWhenClosed = false
        areaWindow.contentView = host
        func editors(in view: NSView) -> [InlineTodoInputScrollView] {
            if let input = view as? InlineTodoInputScrollView { return [input] }
            return view.subviews.flatMap { editors(in: $0) }
        }
        func settle() {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        for size in [NSSize(width: 320, height: 430), NSSize(width: 640, height: 700),
                     NSSize(width: 320, height: 200)] {
            areaWindow.setContentSize(size)
            settle()
            let inputs = editors(in: host)
            expect(inputs.count == 2, "Real list should have two native input areas")
            let input = inputs.first { $0.editor.accessibilityLabel() == "在稍后添加待办" }!
            let frame = input.convert(input.bounds, to: host)
            expect(abs(frame.maxY - host.bounds.height + 6) < 2,
                   "Trailing input did not fill the viewport: \(frame), viewport \(host.bounds)")
            expect(input.editor.frame.height >= input.contentSize.height,
                   "Native text view leaves the lower blank space unclickable")
            for x in [PanelLayout.sidePadding + 1, size.width / 2, size.width - PanelLayout.sidePadding - 1] {
                for y in [CGFloat(6), input.editor.bounds.height / 2, input.editor.bounds.height - 2] {
                    let point = input.editor.convert(NSPoint(x: x, y: y), to: host)
                    let hit = host.hitTest(host.convert(point, to: host.superview))
                    expect(hit === input.editor || hit?.isDescendant(of: input.editor) == true,
                           "Blank-area hit missed native editor at \(point), got \(String(describing: hit)); input \(frame) editor \(input.editor.frame) clip \(input.contentView.frame) clip bounds \(input.contentView.bounds)")
                }
            }
            expect(areaWindow.makeFirstResponder(input.editor), "Blank-area editor cannot receive the caret")
            input.editor.insertText("空白处新增", replacementRange: NSRange(location: NSNotFound, length: 0))
            input.editor.keyDown(with: returnEvent())
            settle()
            expect(store.section(later: true).contains { $0.title == "空白处新增" },
                   "Typing in the expanded blank area did not save to Later")
            store.items = []
        }
        store.items = (0..<30).map { Todo(title: "滚动检查 \($0)", later: $0 > 14) }
        settle()
        let tail = editors(in: host).first { $0.editor.accessibilityLabel() == "在稍后添加待办" }!
        expect(abs(tail.frame.height - PanelLayout.row) < 1, "Long list should not gain extra blank rows")
        let outer = tail.enclosingScrollView!
        expect(outer !== tail, "Scroll regression must exercise the outer list")
        let contentHeight = outer.documentView!.frame.height
        for y: CGFloat in [0, 60, 240, 500, 120, 0] {
            outer.contentView.scroll(to: NSPoint(x: 0, y: y))
            outer.reflectScrolledClipView(outer.contentView)
            settle()
            expect(abs(tail.frame.height - PanelLayout.row) < 1, "Scrolling inflated the trailing input")
            expect(abs(outer.documentView!.frame.height - contentHeight) < 1, "Scrolling changed document height")
        }
        expect(!areaWindow.isVisible, "Blank-area test opened a test window")
        expect(TodoBlankArea.height(viewport: 430, inputTop: 900) == PanelLayout.row,
               "Overflowing list must keep a normal minimum input row")
        expect(PanelLayout.sidePadding == 23, "Text and icon margins differ from the requested 23 pt")
        print("PASS: actual SwiftUI list at 3 viewport sizes; entire blank area hits the native editor (27 points), obtains caret, saves input; resize fills viewport without growing loop.")
        print("PASS: actual native input hit area at 3 widths; both groups accept input, Enter, continuous input, blur and persistence without showing windows.")
        print("PASS: fixed blank-input geometry, input normalization and Unicode multi-line paste; live neighbouring-row displacement, stable cross-group hysteresis (3000 cycles), contiguous variable-height slots, cancellation layout, empty-group sizing; 1:1 grab anchor across 1001 cursor positions; variable-height boundaries; done constraints; cross/empty groups; scroll coordinates; missing-frame cancellation; no-op detection; 1000 preview resolutions without mutation; isolated Store commit and reload.")
    }
}
