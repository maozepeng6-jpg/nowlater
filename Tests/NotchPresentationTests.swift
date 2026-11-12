import Foundation
import AppKit

@main
struct NotchPresentationTests {
    static func main() {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        var gate = NotchDoubleClickGate()
        func click(_ time: Double, x: CGFloat = 100, y: CGFloat = 800,
                   left: Bool = true, inside: Bool = true) -> Bool {
            gate.register(timestamp: time, point: NSPoint(x: x, y: y),
                          leftButton: left, insideTrigger: inside, interval: 0.4)
        }
        expect(!click(1), "One click must not open")
        expect(!click(1), "Duplicate delivery must not count as a second click")
        expect(click(1.2, x: 103), "Nearby second click must open, even across monitor sources")
        expect(!click(1.3), "Opening consumes its pair; a third click starts a new pair")
        gate.reset()
        expect(!click(2) && !click(2.5), "Clicks outside the system interval are singles")
        gate.reset()
        expect(!click(3) && !click(3.1, left: false) && !click(3.2), "Right click must break a pair")
        expect(click(3.3), "Two left clicks after the right click may open")
        gate.reset()
        expect(!click(4) && !click(4.1, inside: false) && !click(4.2), "Outside click must break a pair")
        gate.reset()
        expect(!click(5) && !click(5.1, x: 130), "Two distant clicks must not count as a double click")
        expect(click(5.2, x: 131), "The second position starts its own valid pair")
        gate.reset()
        expect(gate.register(timestamp:6,point:NSPoint(x:100,y:800),leftButton:true,
                             insideTrigger:true,interval:0.4,nativeClickCount:2),
               "A native double-click event inside the trigger must open without a separately delivered first event")
        expect(!gate.register(timestamp:7,point:NSPoint(x:100,y:800),leftButton:true,
                              insideTrigger:false,interval:0.4,nativeClickCount:2),
               "Native double click outside the trigger must not open")
        expect(!gate.register(timestamp:8,point:NSPoint(x:100,y:800),leftButton:false,
                              insideTrigger:true,interval:0.4,nativeClickCount:2),
               "Native right double click must not open")
        expect(!gate.register(timestamp:9,point:NSPoint(x:100,y:800),leftButton:true,
                              insideTrigger:true,interval:0.4,nativeClickCount:1),
               "A native single click must still wait for the second event")
        gate.reset()
        expect(!gate.register(timestamp:10,point:NSPoint(x:100,y:800),leftButton:true,
                              insideTrigger:true,interval:0.4,nativeClickCount:3),
               "An isolated native triple-click count must not bypass the pair gate")

        // Exercise the shared local/global routing with real presentation state:
        // the notch itself is outside the body, but a single click must not close.
        var toggleGate = NotchDoubleClickGate()
        var toggled = NotchPresentation()
        func route(_ time: Double, trigger: Bool = true, body: Bool = false,
                   left: Bool = true, count: Int = 1) -> NotchDoubleClickGate.Action {
            let action = toggleGate.action(timestamp: time, point: NSPoint(x: 100, y: 800),
                                           leftButton: left, insideTrigger: trigger,
                                           insideBody: body, wantsExpanded: toggled.wantsExpanded,
                                           interval: 0.4, nativeClickCount: count)
            switch action {
            case .open: _ = toggled.beginOpening(); toggleGate.reset()
            case .collapse: _ = toggled.beginClosing(); toggleGate.reset()
            case .none: break
            }
            return action
        }
        expect(route(20) == .none && !toggled.wantsExpanded, "Single notch click must stay collapsed")
        expect(route(20.2, count: 2) == .open && toggled.wantsExpanded, "Double notch click must open")
        expect(route(20.2, count: 2) == .none && toggled.wantsExpanded,
               "Duplicate native second event must not undo opening after the gate resets")
        toggled.settle(expanded: true)
        expect(route(21) == .none && toggled.wantsExpanded,
               "First notch click while expanded must not be mistaken for an outside click")
        expect(route(21.2, count: 2) == .collapse && !toggled.wantsExpanded,
               "Second notch click while expanded must close")
        expect(toggled.keepsContentMounted, "Double-click collapse must preserve content for the close animation")
        expect(route(21.2, count: 2) == .none && !toggled.wantsExpanded,
               "Duplicate native second event must not reopen the closing island")
        expect(route(21.3) == .none && route(21.4, count: 2) == .open,
               "Another complete double click may reopen while the close animation is running")
        toggled.settle(expanded: true)
        expect(route(22, trigger: false, body: true, count: 2) == .none && toggled.wantsExpanded,
               "Double click in task text must remain available to the editor")
        expect(route(23, left: false, count: 2) == .none && toggled.wantsExpanded,
               "Right double click on the notch must not toggle")
        expect(route(24, trigger: true, body: true) == .none,
               "The trigger/body overlap must still wait for a second click")
        expect(route(24.2, trigger: false, body: true) == .none,
               "A body click must reset a pending notch pair without closing")
        expect(route(24.3) == .none && toggled.wantsExpanded,
               "Notch clicks separated by a body click must not form a pair")
        expect(route(25, trigger: false) == .collapse && !toggled.wantsExpanded,
               "One click elsewhere must still close an expanded island")
        expect(route(25.1) == .none, "Outside click must reset the pending notch pair")
        expect(route(25.3) == .open, "A full pair after an outside click must open normally")

        var presentation = NotchPresentation()
        expect(!presentation.keepsContentMounted && !presentation.wantsExpanded, "Initial state must be collapsed")
        let firstOpen = presentation.beginOpening()!
        expect(presentation.wantsExpanded && presentation.keepsContentMounted, "Opening must mount content")
        expect(!presentation.acceptsContentInteraction, "Content must not accept edits while still revealing")
        expect(presentation.beginOpening() == nil, "Duplicate open must not restart animation")
        let firstClose = presentation.beginClosing()!
        expect(!presentation.wantsExpanded && presentation.keepsContentMounted, "Closing must retain visible content")
        expect(presentation.beginClosing() == nil, "Duplicate collapse must not restart animation")
        expect(!presentation.complete(firstOpen, expanded: true), "Late opening completion must not undo a close")
        let reopened = presentation.beginOpening()!
        expect(!presentation.complete(firstClose, expanded: false), "Old close must not unmount reopened content")
        expect(presentation.keepsContentMounted && presentation.wantsExpanded, "Reopen must remain visible")
        expect(presentation.complete(reopened, expanded: true), "Newest opening completion should apply")
        expect(presentation.acceptsContentInteraction, "Editing should resume after opening")
        expect(!presentation.complete(reopened, expanded: true), "A completion must only apply once")
        let close = presentation.beginClosing()!
        expect(presentation.keepsContentMounted, "Closing content was removed before frame animation")
        expect(presentation.complete(close, expanded: false) && !presentation.keepsContentMounted,
               "Content should unmount only when the closing animation finishes")
        let interrupted = presentation.beginOpening()!
        presentation.settle(expanded: false)
        expect(!presentation.complete(interrupted, expanded: true) && !presentation.keepsContentMounted,
               "Screen geometry changes must invalidate outstanding animation completions")
        for _ in 0..<1000 {
            let opening = presentation.beginOpening()!
            let closing = presentation.beginClosing()!
            let reopen = presentation.beginOpening()!
            expect(!presentation.complete(closing, expanded: false), "Rapid close/reopen race unmounted content")
            expect(!presentation.complete(opening, expanded: true), "Old open completion was accepted")
            expect(presentation.complete(reopen, expanded: true), "Current open completion was lost")
            let ending = presentation.beginClosing()!
            expect(presentation.complete(ending, expanded: false), "Current close completion was lost")
        }
        print("PASS: notch double-click toggles open/close; single-notch clicks keep state; outside clicks close; body editing and right-clicks do not toggle; duplicate events cannot undo transitions; content retained through closing; stale animation completions rejected; 1000 rapid close/reopen cycles.")
    }
}
