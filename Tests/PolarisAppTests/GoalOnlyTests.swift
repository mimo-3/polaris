import Testing
import PolarisCore
@testable import PolarisApp

@MainActor
struct GoalOnlyTests {
    @Test func emptyNoteKeepsListAndQueueAccessible() {
        let model = NoteModel(state: AppState(today: Day(date: "2026-10-31")), store: nil)
        model.theme.snapshot = true
        model.clickThrough = false
        model.pinned = true
        model.isKey = true
        #expect(model.focusOrder == [.northStar, .starsList, .queueStar])
        #expect(model.handleKey(.tab, modifiers: [], characters: "\t"))
        #expect(model.focusedTarget == .northStar)
        #expect(model.handleKey(.return, modifiers: [], characters: "\r"))
        #expect(model.editing == .northStar)
    }

    @Test func activeAndQueuedStarKeepAchievementFocus() {
        var state = AppState(today: Day(date: "2026-10-31", northStar: "今日の目標"))
        let model = NoteModel(state: state, store: nil)
        #expect(model.focusOrder.prefix(2) == [.northStar, .starQueue])
        state.today.star = nil
        state.starQueue = [NorthStar(text: "次の目標")]
        model.apply(state)
        #expect(model.focusOrder.prefix(2) == [.northStar, .starQueue])
    }
}
