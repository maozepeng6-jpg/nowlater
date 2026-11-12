import Foundation

@main
struct HistoryStoreTests {
    private struct Tasks: Codable {
        var day: String
        var items: [Todo]
    }

    static func main() throws {
        guard let root = ProcessInfo.processInfo.environment["NOWLATER_HOME"],
              root.contains("/nowlater-history-tests.") else {
            fatalError("History tests require an isolated temporary NOWLATER_HOME")
        }
        let folder = URL(fileURLWithPath: root).appendingPathComponent("NowLater")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let today = Store.dayKey()
        let yesterday = Store.dayKey(for: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        let earlier = Store.dayKey(for: Calendar.current.date(byAdding: .day, value: -2, to: Date())!)
        let live = Todo(title: "今天承接且完成的任务", done: true, carried: true)
        let pending = Todo(title: "今天未完成的任务")
        let removedDone = Todo(title: "完成后从主列表移除", done: true)
        let removedPending = Todo(title: "未完成就从主列表移除")
        var olderLive = live
        olderLive.title = "昨天的任务原文"
        olderLive.carried = false
        let olderPending = Todo(title: "昨天未完成")
        let olderDone = Todo(title: "昨天其他完成项", done: true)
        let encoder = JSONEncoder()
        try encoder.encode(Tasks(day: today, items: [live, pending]))
            .write(to: folder.appendingPathComponent("tasks.json"))
        let legacyData = try encoder.encode([
            DayLog(day: today, items: [live, pending, removedDone, removedPending]),
            DayLog(day: yesterday, items: [olderLive, olderPending, olderDone]),
            DayLog(day: earlier, items: [Todo(title: "只有未完成事项的日期")])
        ])
        let logsURL = folder.appendingPathComponent("logs.json")
        let backupURL = folder.appendingPathComponent("logs.before-completed-only.json")
        try legacyData.write(to: logsURL)

        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(condition(), message)
        }
        func entry(_ store: Store, _ day: String, _ id: UUID) -> Todo? {
            store.logs.first { $0.day == day }?.items.first { $0.id == id }
        }
        func allCompleted(_ store: Store) -> Bool {
            store.logs.allSatisfy { !$0.items.isEmpty && $0.items.allSatisfy(\.done) }
        }

        let store = Store()
        expect(store.items == [live, pending], "Migration must not change the main list")
        expect(allCompleted(store), "Only completed items may remain in logs")
        expect(store.logs.count == 2, "Dates containing no completed items must disappear")
        expect(entry(store, today, removedDone.id) != nil, "Removed completed task must stay archived")
        expect(entry(store, today, removedPending.id) == nil, "Removed unfinished task must not be archived")
        expect(entry(store, yesterday, olderPending.id) == nil, "Historical unfinished tasks must be filtered")
        let backup = try Data(contentsOf: backupURL)
        expect(backup == legacyData, "Migration must preserve an exact original backup")
        let persisted = try JSONDecoder().decode([DayLog].self, from: Data(contentsOf: logsURL))
        expect(persisted == store.logs, "Completed-only migration must persist")

        store.updateLog(day: today, itemID: live.id, title: "  今天修改了标题 \n")
        expect(store.items.first?.title == "今天修改了标题", "Today's title edit must update active task")
        expect(entry(store, today, live.id)?.title == "今天修改了标题", "Today's title edit must update log")
        expect(entry(store, yesterday, live.id)?.title == olderLive.title, "Today's edit must not overwrite yesterday")
        expect(store.items.first?.carried == true, "Editing must retain task metadata")
        store.updateLog(day: today, itemID: live.id, title: " \n\t")
        expect(store.items.count == 2 && store.items.first?.title == "今天修改了标题", "Empty history edit must not remove or clear task")

        store.toggleLog(day: today, itemID: live.id)
        expect(store.items.first?.done == false, "Unchecking today's history must leave main task unfinished")
        expect(entry(store, today, live.id) == nil, "Unchecking must immediately remove the log item")
        expect(entry(store, yesterday, live.id)?.done == true, "Today's uncheck must not alter older snapshot")
        expect(store.doneToday == 0, "Main-list completion count must update")
        store.syncDay()
        expect(entry(store, today, live.id) == nil, "Periodic archival must not restore unchecked item")
        store.toggle(live.id)
        expect(entry(store, today, live.id)?.done == true, "Completing main task again must archive it")
        expect(store.logs.first { $0.day == today }?.items.filter { $0.id == live.id }.count == 1, "Recompletion must not duplicate log items")

        store.updateLog(day: yesterday, itemID: live.id, title: "修正昨天的标题")
        expect(entry(store, yesterday, live.id)?.title == "修正昨天的标题", "Historical title should remain editable")
        expect(store.items.first?.title == "今天修改了标题", "Historical edit must not contaminate current same-ID task")
        store.toggleLog(day: yesterday, itemID: live.id)
        expect(entry(store, yesterday, live.id) == nil, "Historical uncheck must remove that day item")
        expect(store.items.first?.done == true && entry(store, today, live.id)?.done == true, "Historical uncheck must not contaminate today's completion")

        store.updateLog(day: today, itemID: removedDone.id, title: "移除后的完成记录仍可编辑")
        expect(entry(store, today, removedDone.id)?.title == "移除后的完成记录仍可编辑", "Removed completed record must stay editable")
        expect(store.items.allSatisfy { $0.id != removedDone.id }, "Editing removed record must never restore it")
        store.syncDay()
        expect(entry(store, today, removedDone.id)?.title == "移除后的完成记录仍可编辑", "Periodic archive must preserve edited removed record")

        store.add("  新增未完成  ", later: true)
        let newlyAdded = store.items.last!
        expect(entry(store, today, newlyAdded.id) == nil, "New unfinished item must not be recorded")
        store.delete(newlyAdded.id)
        expect(entry(store, today, newlyAdded.id) == nil, "Deleting unfinished item must not create history")
        store.toggle(pending.id)
        expect(entry(store, today, pending.id)?.done == true, "Finishing existing task must create history")
        store.clearDone()
        expect(store.items.isEmpty, "Clear completed tasks must remove main-list completed items")
        expect(entry(store, today, pending.id)?.done == true && entry(store, today, live.id)?.done == true, "Clearing completed tasks must preserve their history")

        let beforeInvalid = store.logs
        store.updateLog(day: yesterday, itemID: UUID(), title: "不存在")
        store.toggleLog(day: "1900-01-01", itemID: live.id)
        store.updateLog(day: yesterday, itemID: olderDone.id, title: "  ")
        expect(store.logs == beforeInvalid, "Invalid and empty edits must not mutate logs")

        let reloaded = Store()
        expect(reloaded.logs == store.logs, "All log edits must survive reload")
        expect(reloaded.items == store.items, "Main-list changes must survive reload")
        expect(reloaded.items.allSatisfy { $0.id != removedDone.id }, "Reload must not resurrect removed task")
        reloaded.syncDay()
        expect(entry(reloaded, today, removedDone.id)?.done == true, "Reloaded archive must preserve removed completed item")
        expect(reloaded.csv().contains("\(today),已完成,现在,\"移除后的完成记录仍可编辑\""), "CSV must include edited completed record")
        expect(!reloaded.csv().contains(",未完成,") && allCompleted(reloaded), "CSV and logs must exclude unfinished items")
        let backupAfterReload = try Data(contentsOf: backupURL)
        expect(backupAfterReload == legacyData, "Reload must not overwrite the migration backup")
        reloaded.toggleLog(day: today, itemID: removedDone.id)
        expect(entry(reloaded, today, removedDone.id) == nil && reloaded.items.isEmpty, "Unchecking removed record must remove it without restoring a main task")
        reloaded.toggleLog(day: yesterday, itemID: olderDone.id)
        expect(reloaded.logs.allSatisfy { $0.day != yesterday }, "Removing final completed item must remove the empty date")
        let finalReload = Store()
        expect(finalReload.logs == reloaded.logs, "Unchecked records and removed dates must remain removed after reload")

        // Simulate launching after midnight from an old task file, without changing system time.
        let rolloverRoot = URL(fileURLWithPath: root).appendingPathComponent("rollover")
        let rolloverFolder = rolloverRoot.appendingPathComponent("NowLater")
        try FileManager.default.createDirectory(at: rolloverFolder, withIntermediateDirectories: true)
        let carried = Todo(title: "昨日未完成，今天继续", later: true)
        let completedYesterday = Todo(title: "昨日已完成", done: true)
        let deletedYesterday = Todo(title: "昨日完成后移除", done: true)
        try encoder.encode(Tasks(day: yesterday, items: [carried, completedYesterday]))
            .write(to: rolloverFolder.appendingPathComponent("tasks.json"))
        try encoder.encode([DayLog(day: yesterday, items: [carried, completedYesterday, deletedYesterday])])
            .write(to: rolloverFolder.appendingPathComponent("logs.json"))
        setenv("NOWLATER_HOME", rolloverRoot.path, 1)
        let rolled = Store()
        expect(rolled.items.count == 1 && rolled.items.first?.id == carried.id, "Only unfinished items must carry into the next day")
        expect(rolled.items.first?.carried == true && rolled.items.first?.later == true, "Carried task must preserve group and receive carried flag")
        expect(rolled.logs.allSatisfy { $0.day != today }, "Unfinished carried tasks must not create a new day's archive")
        expect(entry(rolled, yesterday, carried.id) == nil, "Unfinished task must not remain in old day's archive")
        expect(entry(rolled, yesterday, completedYesterday.id) != nil && entry(rolled, yesterday, deletedYesterday.id) != nil, "Rollover must preserve old day's completed and removed-completed tasks")
        rolled.toggle(carried.id)
        expect(entry(rolled, today, carried.id)?.done == true, "Carried task must appear under actual completion day")
        expect(entry(rolled, yesterday, carried.id) == nil, "Completing carried task must not rewrite yesterday")
        rolled.updateLog(day: today, itemID: carried.id, title: "完成当天改名")
        expect(rolled.items.first?.title == "完成当天改名", "Current-day carried task remains editable from history")
        rolled.toggleLog(day: today, itemID: carried.id)
        expect(rolled.items.first?.done == false && rolled.logs.allSatisfy { $0.day != today }, "Unchecking final current-day item must leave active task and remove empty date")
        let rolledReload = Store()
        expect(rolledReload.items == rolled.items && rolledReload.logs == rolled.logs, "Rollover and uncheck changes must persist")
        expect(allCompleted(rolledReload), "All persisted rollover logs must remain completed-only")
        print("PASS: \(checks) completed-only history, migration backup, editing, uncheck, rollover and persistence checks")
    }
}
