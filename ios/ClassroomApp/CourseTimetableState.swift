import Foundation

struct CourseTimetableSnapshot: Codable {
    var courses: [Course]
    var timetable: TimetableData
    var deletedCourses: [Course]? = nil
}

/// One atomic document owns the course map, timetable and persistent import undo.
struct CourseTimetableState: Codable {
    var current: CourseTimetableSnapshot
    var previousImport: CourseTimetableSnapshot?
    var deletedCourses: [Course] = []

    func write(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
    func importing(_ draft: TimetableImportDraft) throws -> CourseTimetableState {
        let semester = draft.semester.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !semester.isEmpty else {
            throw NSError(domain: "TimetableError", code: 4, userInfo: [NSLocalizedDescriptionKey: "请先填写学期"])
        }
        var draft = draft
        draft.semester = semester
        var candidateCourses = current.courses
        var candidateDeleted = deletedCourses
        let colors = ["#007AFF", "#34C759", "#FF9500", "#AF52DE", "#FF2D55", "#5856D6", "#00C7BE", "#32ADE6"]
        var colorIdx = candidateCourses.count

        var activeCourseIdMap: [String: UUID] = [:]

        for item in draft.items where item.isSelected {
            let finalName = item.editedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalName.isEmpty else { continue }

            if let existingIdx = candidateCourses.firstIndex(where: { $0.source == .timetable && $0.semester == semester && ($0.id == item.matchedCourseId || $0.name == finalName) }) {
                candidateCourses[existingIdx].name = finalName
                if !item.teacher.isEmpty { candidateCourses[existingIdx].teacher = item.teacher }
                if !item.room.isEmpty { candidateCourses[existingIdx].room = item.room }
                candidateCourses[existingIdx].semester = draft.semester
                candidateCourses[existingIdx].status = .active
                candidateCourses[existingIdx].source = .timetable
                activeCourseIdMap[item.originalName] = candidateCourses[existingIdx].id
                activeCourseIdMap[finalName] = candidateCourses[existingIdx].id
            } else if item.restoreDeletedCourse == true,
                      let deleted = candidateDeleted.first(where: {
                          $0.id == item.deletedCourseId && $0.semester == semester && $0.source == .timetable
                      }) {
                var restored = deleted
                restored.name = finalName
                restored.status = .active
                if !item.teacher.isEmpty { restored.teacher = item.teacher }
                if !item.room.isEmpty { restored.room = item.room }
                candidateCourses.append(restored)
                candidateDeleted.removeAll { $0.id == restored.id }
                activeCourseIdMap[item.originalName] = restored.id
                activeCourseIdMap[finalName] = restored.id
            } else {
                let newCourse = Course(
                    name: finalName,
                    teacher: item.teacher,
                    room: item.room,
                    colorHex: colors[colorIdx % colors.count],
                    semester: draft.semester,
                    source: .timetable,
                    status: .active
                )
                colorIdx += 1
                candidateCourses.append(newCourse)
                activeCourseIdMap[item.originalName] = newCourse.id
                activeCourseIdMap[finalName] = newCourse.id
            }
        }

        let importedNames = Set(draft.items.filter { $0.isSelected }.map { $0.editedName.trimmingCharacters(in: .whitespacesAndNewlines) })
        for i in 0..<candidateCourses.count {
            if candidateCourses[i].source == .timetable && candidateCourses[i].semester == draft.semester {
                if !importedNames.contains(candidateCourses[i].name) {
                    candidateCourses[i].status = .historical
                }
            }
        }

        var committedSlots: [TimetableSlot] = []
        for var slot in draft.slots {
            if let draftItem = draft.items.first(where: { $0.originalName == slot.courseName }) {
                guard draftItem.isSelected else { continue }
                slot.courseName = draftItem.editedName
                slot.courseId = activeCourseIdMap[draftItem.originalName] ?? activeCourseIdMap[draftItem.editedName]
                if !draftItem.teacher.isEmpty { slot.teacher = draftItem.teacher }
                if !draftItem.room.isEmpty { slot.room = draftItem.room }
            } else if let cId = activeCourseIdMap[slot.courseName] {
                slot.courseId = cId
            }
            guard slot.courseId != nil else { continue }
            slot.semester = draft.semester
            committedSlots.append(slot)
        }


        guard !committedSlots.isEmpty else {
            throw NSError(domain: "TimetableError", code: 5, userInfo: [NSLocalizedDescriptionKey: "没有选中可导入的排课，原课表保持不变"])
        }
        var previous = current
        previous.deletedCourses = deletedCourses
        return CourseTimetableState(
            current: CourseTimetableSnapshot(courses: candidateCourses,
                timetable: TimetableData(currentWeek: max(1, current.timetable.currentWeek), slots: committedSlots, updatedAt: Date())),
            previousImport: previous, deletedCourses: candidateDeleted)
    }

    func removing(_ course: Course) -> CourseTimetableState {
        var updated = self
        updated.current.courses.removeAll { $0.id == course.id }
        updated.current.timetable.slots.removeAll {
            $0.courseId == course.id || ($0.courseId == nil && $0.courseName == course.name && $0.semester == course.semester)
        }
        if course.source == .timetable && !updated.deletedCourses.contains(where: { $0.id == course.id }) {
            updated.deletedCourses.append(course)
        }
        return updated
    }

}
