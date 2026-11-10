import Foundation

@main
struct ClassroomTimetableStateTests {
    static func main() throws {
        let manual = Course(name: "高等数学", semester: "2026-2027-1", source: .manual)
        let initial = CourseTimetableState(current: CourseTimetableSnapshot(courses: [manual], timetable: TimetableData()), previousImport: nil)
        let slot = TimetableSlot(courseName: "高等数学", day: 1, fromPeriod: 1, toPeriod: 2)
        let draft = TimetableImportDraft(semester: "2026-2027-1", slots: [slot], items: [DraftCourseItem(originalName: "高等数学")])
        let first = try initial.importing(draft)
        let firstID = first.current.timetable.slots[0].courseId!
        precondition(firstID != manual.id && first.current.courses.count == 2)
        precondition(first.current.courses.first(where: { $0.id == manual.id })?.source == .manual)
        let repeatImport = try first.importing(draft)
        precondition(repeatImport.current.courses.count == 2)
        precondition(repeatImport.current.timetable.slots[0].courseId == firstID)
        var nextSemester = draft
        nextSemester.semester = "2026-2027-2"
        let second = try repeatImport.importing(nextSemester)
        precondition(second.current.courses.count == 3)
        precondition(second.current.timetable.slots[0].courseId != firstID)
        precondition(second.current.courses.first(where: { $0.id == firstID })?.semester == "2026-2027-1")
        let imported = first.current.courses.first { $0.id == firstID }!
        let removed = first.removing(imported)
        precondition(removed.current.timetable.slots.isEmpty && removed.deletedCourses[0].id == firstID)
        precondition(removed.current.courses[0].id == manual.id)
        var restore = draft
        restore.items[0].deletedCourseId = firstID
        restore.items[0].restoreDeletedCourse = true
        let restored = try removed.importing(restore)
        precondition(restored.current.timetable.slots[0].courseId == firstID)
        precondition(restored.deletedCourses.isEmpty)
        precondition(restored.previousImport?.deletedCourses?.first?.id == firstID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("classroom-state-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        try restored.write(to: url)
        let recovered = try JSONDecoder().decode(CourseTimetableState.self, from: Data(contentsOf: url))
        precondition(recovered.current.timetable.slots[0].courseId == firstID)
        precondition(recovered.previousImport?.courses.count == removed.current.courses.count)
        precondition(recovered.previousImport?.timetable.slots.isEmpty == true)
        var invalid = draft
        invalid.semester = ""
        do { _ = try recovered.importing(invalid); preconditionFailure("unknown semester must require confirmation") }
        catch { }
        invalid = draft
        invalid.items[0].isSelected = false
        do { _ = try recovered.importing(invalid); preconditionFailure("empty import must preserve the original timetable") }
        catch { }
        let persisted = try JSONDecoder().decode(CourseTimetableState.self, from: Data(contentsOf: url))
        precondition(persisted.current.timetable.slots[0].courseId == firstID)
        print("Production timetable identity, deletion, restore and persisted undo checks passed")
    }
}
