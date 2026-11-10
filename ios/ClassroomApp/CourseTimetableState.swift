import Foundation

struct CourseTimetableSnapshot: Codable {
    var courses: [Course]
    var timetable: TimetableData
}

/// One atomic document owns the course map, timetable and persistent import undo.
struct CourseTimetableState: Codable {
    var current: CourseTimetableSnapshot
    var previousImport: CourseTimetableSnapshot?
    var deletedCourses: [Course] = []

    func write(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
