import SwiftUI
import AppKit

final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    @Published var addToLater = false
    @Published var showingHistory = false

    @Published var width: CGFloat
    /// 只在结束缩放时保存偏好，拖动过程不写磁盘。
    @Published var manualHeight: CGFloat

    func persistSize() {
        UserDefaults.standard.set(Double(width), forKey: "panelWidth")
        UserDefaults.standard.set(Double(manualHeight), forKey: "panelHeight")
    }

    /// 某一行正在编辑：这时 Esc 交给输入框，不收起面板
    @Published var editing = false

    init() {
        let d = UserDefaults.standard
        width = d.object(forKey: "panelWidth") == nil
            ? PanelLayout.width
            : CGFloat(d.double(forKey: "panelWidth"))
        manualHeight = d.object(forKey: "panelHeight") == nil
            ? 0
            : CGFloat(d.double(forKey: "panelHeight"))
    }
}

enum PanelLayout {
    static let width: CGFloat = 320
    static let row: CGFloat = 26
    static let header: CGFloat = 24
    static let sidePadding: CGFloat = 23

    /// Use the same font and explicit line breaks as the native row editor.
    static func rowHeight(_ title: String, width: CGFloat) -> CGFloat {
        let usable = max(width - sidePadding * 2 - 42, 100)
        let bounds = (title as NSString).boundingRect(
            with: NSSize(width: usable, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12.5)])
        return max(row, ceil(bounds.height) + 10)
    }

    static func rowsHeight(_ items: [Todo], width: CGFloat) -> CGFloat {
        items.reduce(row) { $0 + rowHeight($1.title, width: width) }
    }

    /// 每组末尾自带一个空白输入行，不再预留独立底部输入栏。
    static func height(now: [Todo], later: [Todo], width: CGFloat = PanelLayout.width, cap: CGFloat = 430) -> CGFloat {
        let rows = rowsHeight(now, width: width) + rowsHeight(later, width: width)
        let chrome: CGFloat = 6 + header + 12        // 标题区
            + 16 + 16                                // 分组标题
            + 14 + 1                                 // 中间分隔线
            + 7                                      // 底部缩放热区
        return min(max(rows + chrome, 178), cap)
    }
}

struct IslandView: View {
    @ObservedObject var store: Store
    @ObservedObject var state: IslandState
    /// 刘海带的高度：卡片从屏幕最顶端开始画，内容整体下移这么多，视觉上就是刘海自己长出来
    var topInset: CGFloat
    var onOpenLog: () -> Void
    var onBack: () -> Void
    var onResize: (PanelResizeEdge, PanelResizePhase, NSPoint) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear

            if state.expanded {
                ZStack(alignment: .top) {
                    card
                    Group {
                        if state.showingHistory {
                            HistoryView(store: store, onBack: onBack, editState: state)
                        } else {
                            content
                        }
                    }
                    .padding(.top, topInset)
                    .padding(.bottom, 7)
                }
                .overlay(alignment: .top) { resizeHandles }
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .environment(\.colorScheme, .dark)
        .tint(.gray)
        .accentColor(.gray)

    }

    // MARK: - Shell

    /// 顶部两个角是直角（和屏幕顶边、刘海连成一体直接伸下来），只有下面两个角是圆的，
    /// 圆角半径 11 与刘海本身的圆角一致
    private var card: some View {
        NotchCardShape(radius: 11)
            .fill(Color.black)
            .shadow(color: Color.black.opacity(0.30), radius: 14, x: 0, y: 6)
    }
    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            header
            TodoListView(store: store, editState: state)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(store.todayTitle)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.52))

            if store.carriedCount > 0 {
                Text("承接 \(store.carriedCount)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.white.opacity(0.30))
            }

            Spacer(minLength: 6)

            if !store.items.isEmpty {
                Text("\(store.doneToday)/\(store.items.count)")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.30))
            }

            Button(action: onOpenLog) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开每日汇总表")

            QuitButton()
        }
        .padding(.horizontal, PanelLayout.sidePadding)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(height: PanelLayout.header + 12, alignment: .top)
    }

    // MARK: - Resize

    private var resizeHandles: some View {
        ZStack {
            HStack(spacing: 0) {
                PanelResizeHandle(edge: .left, onResize: onResize).frame(width: 7)
                Spacer(minLength: 0)
                PanelResizeHandle(edge: .right, onResize: onResize).frame(width: 7)
            }
            .padding(.top, topInset)
            .padding(.bottom, 9)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                PanelResizeHandle(edge: .bottom, onResize: onResize).frame(height: 9)
            }
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Capsule().fill(Color.white.opacity(0.22))
                    .frame(width: 26, height: 3).padding(.bottom, 3)
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


}

/// 顶部直角、底部圆角：贴住屏幕顶边时，看起来就是刘海直接向下伸出来的一块
struct NotchCardShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
