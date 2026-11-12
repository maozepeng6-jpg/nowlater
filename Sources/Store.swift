import Foundation
import AppKit
import Combine

struct Todo: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var later: Bool = false
    var done: Bool = false
    var createdAt: Date = Date()
    /// 从昨天承接过来的（昨天没做完，或一直放在「稍后」）
    var carried: Bool = false

    init(id: UUID = UUID(),
         title: String,
         later: Bool = false,
         done: Bool = false,
         createdAt: Date = Date(),
         carried: Bool = false) {
        self.id = id
        self.title = title
        self.later = later
        self.done = done
        self.createdAt = createdAt
        self.carried = carried
    }

    enum CodingKeys: String, CodingKey { case id, title, later, done, createdAt, carried }

    /// 手写解码：老数据里没有 carried 字段，不能因此丢掉整份清单
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        later = try c.decodeIfPresent(Bool.self, forKey: .later) ?? false
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        carried = try c.decodeIfPresent(Bool.self, forKey: .carried) ?? false
    }
}

/// 某一天已完成事项的快照
struct DayLog: Codable, Identifiable, Equatable {
    var day: String            // yyyy-MM-dd
    var items: [Todo]

    var id: String { day }
    var doneCount: Int { items.filter(\.done).count }
    var total: Int { items.count }
}

final class Store: ObservableObject {
    @Published var items: [Todo] = []
    /// 只包含已完成事项的历史汇总，新的一天在前；空日期不保留。
    @Published private(set) var logs: [DayLog] = []
    /// 今天的日期文字（跨天时自动刷新）
    @Published private(set) var todayTitle: String = ""

    private let folder: URL
    private let tasksURL: URL
    private let logsURL: URL
    private var activeDay: String
    private var timer: Timer?
    /// 今天已完成的条目（含完成后从主列表移除的）；取消完成时从这里移出。
    private var todaySeen: [Todo] = []
    /// 旧版包含未完成项的原始记录，备份成功前不能覆盖原日志。
    private var pendingLogMigrationBackup: Data?

    private struct Persisted: Codable {
        var day: String
        var items: [Todo]
    }

    // MARK: - Date helpers

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f
    }()

    private static let logTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(for date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    static func displayDay(_ key: String) -> String {
        guard let d = logTitleFormatter.date(from: key) else { return key }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天 · " + titleFormatter.string(from: d) }
        if cal.isDateInYesterday(d) { return "昨天 · " + titleFormatter.string(from: d) }
        return titleFormatter.string(from: d)
    }

    // MARK: - Init

    init() {
        // 允许测试/调试时把数据指到别处，避免误碰真实数据
        if let root = ProcessInfo.processInfo.environment["NOWLATER_HOME"], !root.isEmpty {
            folder = URL(fileURLWithPath: root).appendingPathComponent("NowLater", isDirectory: true)
        } else {
            folder = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("NowLater", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        tasksURL = folder.appendingPathComponent("tasks.json")
        logsURL = folder.appendingPathComponent("logs.json")
        activeDay = Store.dayKey()

        loadLogs()
        loadTasks()

        let today = Store.dayKey()
        // 重启后保留当天已完成记录，包括完成后从主列表移除的事项。
        if let existing = logs.first(where: { $0.day == activeDay }) {
            todaySeen = existing.items
        }
        if activeDay != today {
            rollover(to: today)
        }
        todayTitle = Store.titleFormatter.string(from: Date())
        archiveToday()
        startTimer()

        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncDay()
        }
    }

    deinit { timer?.invalidate() }

    private func startTimer() {
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.syncDay()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 每 20 秒、以及唤醒时调用：跨过零点就换日，并把今天的最新状态写进汇总
    func syncDay() {
        let key = Store.dayKey()
        if key != activeDay { rollover(to: key) }
        let title = Store.titleFormatter.string(from: Date())
        if title != todayTitle { todayTitle = title }
        archiveToday()
    }

    // MARK: - Grouping

    /// 组内顺序跟随数组顺序（拖动换序就是改数组位置），完成的沉到组尾
    func section(later: Bool) -> [Todo] {
        items.enumerated()
            .filter { $0.element.later == later }
            .sorted { a, b in
                if a.element.done != b.element.done { return !a.element.done }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    var hasDone: Bool { items.contains { $0.done } }
    var carriedCount: Int { items.filter { $0.carried && !$0.done }.count }
    var doneToday: Int { items.filter(\.done).count }

    // MARK: - Mutations

    func add(_ title: String, later: Bool) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(Todo(title: trimmed, later: later))
        save()
    }

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done.toggle()
        save()
    }

    func move(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        relocate(id, toEndOf: !items[i].later, uncheck: true)
    }

    /// 拖动落点：插到目标行的上/下方（同组换序；跨组则同时换组）
    func relocate(_ id: UUID, relativeTo targetID: UUID, above: Bool) {
        guard id != targetID,
              let i = items.firstIndex(where: { $0.id == id }),
              items.contains(where: { $0.id == targetID })
        else { return }
        var moving = items.remove(at: i)
        guard let j = items.firstIndex(where: { $0.id == targetID }) else { return }
        moving.later = items[j].later
        items.insert(moving, at: above ? j : j + 1)
        save()
    }

    /// 拖到组的末尾（或拖过分隔线换组）
    func relocate(_ id: UUID, toEndOf later: Bool, uncheck: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var moving = items.remove(at: i)
        moving.later = later
        if uncheck { moving.done = false }
        if let last = items.lastIndex(where: { $0.later == later }) {
            items.insert(moving, at: last + 1)
        } else {
            items.append(moving)
        }
        save()
    }

    /// 原地编辑：改文字；清空 = 删掉这一条
    func update(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(id)
            return
        }
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[i].title != trimmed else { return }
        items[i].title = trimmed
        save()
    }

    /// 汇总中的空编辑不会删除记录；今天同步待办，过往日期只修改该日快照。
    func updateLog(day: String, itemID: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateLog(day: day, itemID: itemID) { $0.title = trimmed }
    }

    func toggleLog(day: String, itemID: UUID) {
        mutateLog(day: day, itemID: itemID) { $0.done.toggle() }
    }

    private func mutateLog(day: String, itemID: UUID, change: (inout Todo) -> Void) {
        // 编辑时也检查跨日，避免午夜后把昨日快照写进新一天。
        syncDay()
        guard let logIndex = logs.firstIndex(where: { $0.day == day }),
              let itemIndex = logs[logIndex].items.firstIndex(where: { $0.id == itemID }) else { return }
        let original = logs[logIndex].items[itemIndex]
        var updated = original
        change(&updated)
        guard updated != original else { return }

        if day == activeDay {
            if let seenIndex = todaySeen.firstIndex(where: { $0.id == itemID }) {
                if updated.done { todaySeen[seenIndex] = updated }
                else { todaySeen.remove(at: seenIndex) }
            } else if updated.done {
                todaySeen.append(updated)
            }
            // 已从今天待办删除的条目仍可改汇总，但不让它重新出现在待办里。
            if let currentIndex = items.firstIndex(where: { $0.id == itemID }) {
                items[currentIndex] = updated
            }
            save()
        } else {
            // 承接任务会在多个日期使用同一 ID，不能据 ID 改动今天的任务。
            var snapshot = logs[logIndex].items
            snapshot[itemIndex] = updated
            archive(day: day, items: snapshot)
        }
    }

    func delete(_ id: UUID) {
        mergeToday()     // 完成后删除仍留在汇总；未完成事项不归档。
        items.removeAll { $0.id == id }
        save()
    }

    func clearDone() {
        mergeToday()
        items.removeAll { $0.done }
        save()
    }

    /// 把昨天没做完的重新摆到「现在」最前面（手动催一下）
    func promoteCarried() {
        for i in items.indices where items[i].carried && !items[i].done {
            items[i].later = false
        }
        save()
    }

    // MARK: - Day rollover

    /// 换日：归档旧的一天，只把没打勾的带到今天（「稍后」的也一起带过来）
    private func rollover(to today: String) {
        let oldDay = activeDay
        if !oldDay.isEmpty, oldDay != today {
            mergeToday()
            archive(day: oldDay, items: todaySeen)
        }
        items = items
            .filter { !$0.done }
            .map { todo in
                var t = todo
                t.carried = true
                return t
            }
        todaySeen = []             // 承接过来的都是未完成事项，完成后才进入新一天汇总。
        activeDay = today
        save()
    }

    // MARK: - Archive

    /// 当天只归档已完成事项；已完成后移除的保留，重新取消完成的移出。
    private func archiveToday() {
        mergeToday()
        archive(day: activeDay, items: todaySeen)
    }

    private func mergeToday() {
        for item in items {
            if let i = todaySeen.firstIndex(where: { $0.id == item.id }) {
                if item.done { todaySeen[i] = item }
                else { todaySeen.remove(at: i) }
            } else if item.done {
                todaySeen.append(item)
            }
        }
    }

    private func archive(day: String, items snapshot: [Todo]) {
        guard !day.isEmpty else { return }
        let completed = snapshot.filter(\.done)
        if let i = logs.firstIndex(where: { $0.day == day }) {
            if logs[i].items == completed { return }
            if completed.isEmpty { logs.remove(at: i) }
            else { logs[i].items = completed }
        } else {
            guard !completed.isEmpty else { return }
            logs.append(DayLog(day: day, items: completed))
            logs.sort { $0.day > $1.day }
            if logs.count > 400 { logs.removeLast(logs.count - 400) }
        }
        saveLogs()
    }

    // MARK: - Export

    /// 汇总成 CSV：日期,状态,分组,事项
    func csv() -> String {
        var rows = ["日期,状态,分组,事项"]
        for log in logs {
            for item in log.items where item.done {
                let state = "已完成"
                let group = item.later ? "稍后" : "现在"
                let title = item.title.replacingOccurrences(of: "\"", with: "\"\"")
                rows.append("\(log.day),\(state),\(group),\"\(title)\"")
            }
        }
        return rows.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func loadTasks() {
        guard let data = try? Data(contentsOf: tasksURL) else {
            activeDay = Store.dayKey()
            return
        }
        let decoder = JSONDecoder()
        if let p = try? decoder.decode(Persisted.self, from: data) {
            items = p.items
            activeDay = p.day.isEmpty ? Store.dayKey() : p.day
        } else if let legacy = try? decoder.decode([Todo].self, from: data) {
            // 老版本只存了一个数组
            items = legacy
            activeDay = Store.dayKey()
        } else {
            activeDay = Store.dayKey()
        }
    }

    private func loadLogs() {
        guard let data = try? Data(contentsOf: logsURL),
              let decoded = try? JSONDecoder().decode([DayLog].self, from: data)
        else { return }
        logs = decoded.compactMap { log in
            let completed = log.items.filter(\.done)
            return completed.isEmpty ? nil : DayLog(day: log.day, items: completed)
        }.sorted { $0.day > $1.day }
        if logs != decoded.sorted(by: { $0.day > $1.day }) {
            // 迁移仅影响汇总，不删主列表；完整旧日志另存一次，可手工恢复。
            let backupURL = folder.appendingPathComponent("logs.before-completed-only.json")
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                pendingLogMigrationBackup = data
            }
            saveLogs()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = Persisted(day: activeDay, items: items)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: tasksURL, options: .atomic)
        archiveToday()
    }

    private func saveLogs() {
        if let original = pendingLogMigrationBackup {
            do {
                try original.write(to: folder.appendingPathComponent("logs.before-completed-only.json"), options: .atomic)
                pendingLogMigrationBackup = nil
            } catch {
                // 保留原始日志，后续保存时重试备份，绝不在备份失败时覆盖旧数据。
                NSLog("NowLater: 无法备份旧版日程汇总，暂未覆盖原日志：%@", error.localizedDescription)
                return
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(logs) else { return }
        try? data.write(to: logsURL, options: .atomic)
    }
}
