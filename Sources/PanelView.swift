import SwiftUI
import AppKit

struct PanelView: View {
    @ObservedObject var store: Store
    var onOpenLog: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            TodoListView(store: store)
        }
        .padding(.bottom, 7)
        .frame(width: 300)
        .tint(.gray)
        .accentColor(.gray)

    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(store.todayTitle)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.secondary)
            if store.carriedCount > 0 {
                Text("承接 \(store.carriedCount)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.secondary.opacity(0.7))
            }
            Spacer(minLength: 6)
            if !store.items.isEmpty {
                Text("\(store.doneToday)/\(store.items.count)")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(Color.secondary.opacity(0.7))
            }
            Button(action: onOpenLog) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 18, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开每日汇总表")
        }
        .padding(.horizontal, PanelLayout.sidePadding)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }


}

