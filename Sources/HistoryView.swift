import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 每日已完成事项汇总，可编辑文字或取消完成，并导出 CSV。
struct HistoryView: View {
    @ObservedObject var store: Store
    var onBack: () -> Void
    var editState: IslandState? = nil
    @State private var note = ""
    @State private var isExporting = false
    @State private var editingEntry: HistoryEntryID?

    private var totalDone: Int { store.logs.reduce(0) { $0 + $1.doneCount } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { editState?.editing = false }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 27, height: 31)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回待办")
            .accessibilityLabel("返回待办")

            VStack(alignment: .leading, spacing: 2) {
                Text("日程汇总")
                    .font(.system(size: 15, weight: .semibold))
                Text("共 \(store.logs.count) 天 · 已完成 \(totalDone) 件")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            QuitButton()
        }
        .padding(.horizontal, PanelLayout.sidePadding)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if store.logs.isEmpty {
            VStack(spacing: 6) {
                Text("还没有完成记录")
                    .font(.system(size: 13))
                Text("勾选完成后，事项会自动按天记录在这里")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.logs) { log in
                        daySection(log)
                    }
                }
                .padding(.horizontal, PanelLayout.sidePadding)
                .padding(.vertical, 10)
            }
        }
    }

    private func daySection(_ log: DayLog) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(Store.displayDay(log.day))
                    .font(.system(size: 12, weight: .semibold))
                Text("完成 \(log.doneCount) 件")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ForEach(log.items) { item in
                HistoryTaskRow(item: item, onSave: { title in
                    store.updateLog(day: log.day, itemID: item.id, title: title)
                }, onToggle: {
                    store.toggleLog(day: log.day, itemID: item.id)
                }, onEditingChanged: { editing in
                    let key = HistoryEntryID(day: log.day, itemID: item.id)
                    if editing {
                        editingEntry = key
                        editState?.editing = true
                    } else if editingEntry == key {
                        editingEntry = nil
                        editState?.editing = false
                    }
                })
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Button {
                    exportCSV()
                } label: {
                    Label("导出 CSV…", systemImage: "square.and.arrow.up")
                        .font(.system(size: 11))
                }
                .disabled(isExporting)
                Spacer(minLength: 0)
            }
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, PanelLayout.sidePadding)
        .padding(.vertical, 10)
    }

    private func exportCSV() {
        guard !isExporting, let parentWindow = NSApp.keyWindow,
              parentWindow.attachedSheet == nil else { return }

        parentWindow.makeFirstResponder(nil)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NowLater-日程汇总.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        isExporting = true
        note = ""
        let text = "\u{FEFF}" + store.csv()   // BOM：Excel 打开中文不乱码
        // 挂在当前刘海面板上，避免独立模态窗口触发面板失焦收起。
        panel.beginSheetModal(for: parentWindow) { response in
            isExporting = false
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                note = "已导出到 \(url.lastPathComponent)"
            } catch {
                note = "导出失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct HistoryEntryID: Equatable {
    let day: String
    let itemID: UUID
}

private struct HistoryTaskRow: View {
    let item: Todo
    let onSave: (String) -> Void
    let onToggle: () -> Void
    let onEditingChanged: (Bool) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Button {
                commit()
                onToggle()
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(item.done ? Color.primary : Color.secondary.opacity(0.55))
                    .frame(width: 17, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("取消完成，并从汇总移出")
            .accessibilityLabel("取消完成并从汇总移出：\(item.title)")

            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onChange(of: focused) { if !$0 { commit() } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(item.title)
                    .font(.system(size: 12))
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: begin)
                    .help("点击编辑")
            }

            if item.later { badge("稍后") }
        }
        .frame(minHeight: 22)
        .onDisappear(perform: commit)
        .onReceive(NotificationCenter.default.publisher(for: .nowLaterWillQuit)) { _ in
            commit()
        }
    }

    private func badge(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 8.5))
            .foregroundStyle(Color.secondary.opacity(0.75))
            .padding(.horizontal, 3.5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.secondary.opacity(0.12)))
            .fixedSize()
    }

    private func begin() {
        draft = item.title
        editing = true
        onEditingChanged(true)
        DispatchQueue.main.async {
            if editing { focused = true }
        }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        onEditingChanged(false)
        focused = false
        onSave(draft)
    }

    private func cancel() {
        guard editing else { return }
        editing = false
        onEditingChanged(false)
        focused = false
    }
}
