import AppKit
import SwiftUI

enum PanelResizeEdge { case left, right, bottom }
enum PanelResizePhase { case began, changed, ended }

/// 全局鼠标位移相对按下时的窗口尺寸计算，避免移动窗口后坐标反馈及抓取边缘跳变。
struct PanelResizeSession {
    let edge: PanelResizeEdge
    let startPointer: NSPoint
    let startFrame: NSRect

    func frame(at pointer: NSPoint, minWidth: CGFloat, maxWidth: CGFloat,
               minHeight: CGFloat, maxHeight: CGFloat) -> NSRect {
        var width = startFrame.width
        var height = startFrame.height
        switch edge {
        case .left: width -= (pointer.x - startPointer.x) * 2
        case .right: width += (pointer.x - startPointer.x) * 2
        case .bottom: height -= pointer.y - startPointer.y
        }
        width = min(max(width, minWidth), maxWidth)
        height = min(max(height, minHeight), maxHeight)
        return NSRect(x: startFrame.midX - width / 2, y: startFrame.maxY - height,
                      width: width, height: height)
    }
}

/// 使用原生鼠标事件，直接调整 NSPanel，不等 SwiftUI/Combine 的下一轮刷新。
struct PanelResizeHandle: NSViewRepresentable {
    let edge: PanelResizeEdge
    let onResize: (PanelResizeEdge, PanelResizePhase, NSPoint) -> Void

    func makeNSView(context: Context) -> ResizeTrackingView {
        let view = ResizeTrackingView()
        view.edge = edge
        view.onResize = onResize
        return view
    }

    func updateNSView(_ view: ResizeTrackingView, context: Context) {
        view.edge = edge
        view.onResize = onResize
    }
}

final class ResizeTrackingView: NSView {
    var edge: PanelResizeEdge = .bottom
    var onResize: ((PanelResizeEdge, PanelResizePhase, NSPoint) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: edge == .bottom ? .resizeUpDown : .resizeLeftRight)
    }
    private func location(_ event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
    override func mouseDown(with event: NSEvent) { onResize?(edge, .began, location(event)) }
    override func mouseDragged(with event: NSEvent) { onResize?(edge, .changed, location(event)) }
    override func mouseUp(with event: NSEvent) { onResize?(edge, .ended, location(event)) }
}
