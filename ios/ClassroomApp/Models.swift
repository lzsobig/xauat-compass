import Foundation

public enum RecordingMode: String, Codable, CaseIterable, Sendable {
    case realtime = "realtime"
    case recordOnly = "recordOnly"
    
    public var title: String {
        switch self {
        case .realtime: return "实时转写"
        case .recordOnly: return "仅录音"
        }
    }
}

public enum TranscriptionEngine: String, Codable, CaseIterable, Sendable {
    case apple = "apple"
    case stepfun = "stepfun"
    
    public var title: String {
        switch self {
        case .apple: return "苹果原生识别"
        case .stepfun: return "阶跃星辰 ASR (云端高精)"
        }
    }
    
    public var shortTitle: String {
        switch self {
        case .apple: return "苹果原生"
        case .stepfun: return "阶跃 ASR"
        }
    }
    
    public var badge: String {
        switch self {
        case .apple: return "免Key/离线"
        case .stepfun: return "stepaudio-2.5-asr"
        }
    }
}

public enum LessonStatus: String, Codable, Sendable {
    case recording = "recording"
    case paused = "paused"
    case interrupted = "interrupted"
    case completed = "completed"
    
    public var title: String {
        switch self {
        case .recording: return "录音中"
        case .paused: return "已暂停"
        case .interrupted: return "录音中断"
        case .completed: return "已完成"
        }
    }
}

public struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var isMarked: Bool
    
    public init(id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval, text: String, isMarked: Bool = false) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.isMarked = isMarked
    }
}

public enum NoteStyle: String, Codable, CaseIterable, Sendable {
    case detailedOutline = "detailedOutline"
    case keyPoints = "keyPoints"
    case examReview = "examReview"
    
    public var title: String {
        switch self {
        case .detailedOutline: return "详细纲要"
        case .keyPoints: return "核心要点"
        case .examReview: return "考点复习"
        }
    }
}

public struct LessonNote: Identifiable, Codable, Sendable {
    public var id: UUID
    public var style: NoteStyle
    public var content: String
    public var createdAt: Date
    
    public init(id: UUID = UUID(), style: NoteStyle, content: String, createdAt: Date = Date()) {
        self.id = id
        self.style = style
        self.content = content
        self.createdAt = createdAt
    }
}

public struct QAPair: Identifiable, Codable, Sendable {
    public var id: UUID
    public var question: String
    public var answer: String
    public var citationSeconds: TimeInterval?
    public var createdAt: Date
    
    public init(id: UUID = UUID(), question: String, answer: String, citationSeconds: TimeInterval? = nil, createdAt: Date = Date()) {
        self.id = id
        self.question = question
        self.answer = answer
        self.citationSeconds = citationSeconds
        self.createdAt = createdAt
    }
}

public enum CourseSource: String, Codable, CaseIterable, Sendable {
    case timetable = "timetable"
    case manual = "manual"
}

public enum CourseStatus: String, Codable, CaseIterable, Sendable {
    case active = "active"       // 当前学期在学
    case historical = "historical" // 历史学期/已结课
}

public struct Course: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var teacher: String
    public var room: String
    public var colorHex: String
    public var semester: String
    public var source: CourseSource
    public var status: CourseStatus
    public var createdAt: Date
    
    public init(
        id: UUID = UUID(),
        name: String,
        teacher: String = "",
        room: String = "",
        colorHex: String = "#0A84FF",
        semester: String = "2026-2027-1",
        source: CourseSource = .timetable,
        status: CourseStatus = .active,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.teacher = teacher
        self.room = room
        self.colorHex = colorHex
        self.semester = semester
        self.source = source
        self.status = status
        self.createdAt = createdAt
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, teacher, room, colorHex, semester, source, status, createdAt
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        teacher = try container.decodeIfPresent(String.self, forKey: .teacher) ?? ""
        room = try container.decodeIfPresent(String.self, forKey: .room) ?? ""
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "#0A84FF"
        semester = try container.decodeIfPresent(String.self, forKey: .semester) ?? "2026-2027-1"
        source = try container.decodeIfPresent(CourseSource.self, forKey: .source) ?? .timetable
        status = try container.decodeIfPresent(CourseStatus.self, forKey: .status) ?? .active
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public struct TimetableSlot: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var courseId: UUID?
    public var courseName: String
    public var teacher: String
    public var room: String
    public var day: Int // 1 (Mon) - 7 (Sun)
    public var fromPeriod: Int // 1 - 12
    public var toPeriod: Int // 1 - 12
    public var weekFrom: Int
    public var weekTo: Int
    public var parity: String // "all", "odd", "even"
    public var semester: String
    
    public init(
        id: UUID = UUID(),
        courseId: UUID? = nil,
        courseName: String,
        teacher: String = "",
        room: String = "",
        day: Int,
        fromPeriod: Int,
        toPeriod: Int,
        weekFrom: Int = 1,
        weekTo: Int = 20,
        parity: String = "all",
        semester: String = "2026-2027-1"
    ) {
        self.id = id
        self.courseId = courseId
        self.courseName = courseName
        self.teacher = teacher
        self.room = room
        self.day = day
        self.fromPeriod = fromPeriod
        self.toPeriod = toPeriod
        self.weekFrom = weekFrom
        self.weekTo = weekTo
        self.parity = parity
        self.semester = semester
    }
    
    enum CodingKeys: String, CodingKey {
        case id, courseId, courseName, teacher, room, day, fromPeriod, toPeriod, weekFrom, weekTo, parity, semester
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        courseId = try container.decodeIfPresent(UUID.self, forKey: .courseId)
        courseName = try container.decode(String.self, forKey: .courseName)
        teacher = try container.decodeIfPresent(String.self, forKey: .teacher) ?? ""
        room = try container.decodeIfPresent(String.self, forKey: .room) ?? ""
        day = try container.decode(Int.self, forKey: .day)
        fromPeriod = try container.decode(Int.self, forKey: .fromPeriod)
        toPeriod = try container.decode(Int.self, forKey: .toPeriod)
        weekFrom = try container.decodeIfPresent(Int.self, forKey: .weekFrom) ?? 1
        weekTo = try container.decodeIfPresent(Int.self, forKey: .weekTo) ?? 20
        parity = try container.decodeIfPresent(String.self, forKey: .parity) ?? "all"
        semester = try container.decodeIfPresent(String.self, forKey: .semester) ?? "2026-2027-1"
    }
}

public struct TimetableData: Codable, Sendable {
    public var semester: String
    public var currentWeek: Int
    public var slots: [TimetableSlot]
    public var updatedAt: Date
    
    public init(semester: String = "2026-2027-1", currentWeek: Int = 1, slots: [TimetableSlot] = [], updatedAt: Date = Date()) {
        self.semester = semester
        self.currentWeek = currentWeek
        self.slots = slots
        self.updatedAt = updatedAt
    }
    
    enum CodingKeys: String, CodingKey {
        case semester, currentWeek, slots, updatedAt
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        semester = try container.decodeIfPresent(String.self, forKey: .semester) ?? "2026-2027-1"
        currentWeek = try container.decodeIfPresent(Int.self, forKey: .currentWeek) ?? 1
        slots = try container.decodeIfPresent([TimetableSlot].self, forKey: .slots) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

public enum DraftAction: String, Codable, Sendable {
    case create = "create"
    case matchExisting = "matchExisting"
    case ignore = "ignore"
}

public struct DraftCourseItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var originalName: String
    public var editedName: String
    public var teacher: String
    public var room: String
    public var matchedCourseId: UUID?
    public var action: DraftAction
    public var isSelected: Bool
    
    public init(
        id: UUID = UUID(),
        originalName: String,
        editedName: String? = nil,
        teacher: String = "",
        room: String = "",
        matchedCourseId: UUID? = nil,
        action: DraftAction = .create,
        isSelected: Bool = true
    ) {
        self.id = id
        self.originalName = originalName
        self.editedName = editedName ?? originalName
        self.teacher = teacher
        self.room = room
        self.matchedCourseId = matchedCourseId
        self.action = action
        self.isSelected = isSelected
    }
}

public struct TimetableImportDraft: Identifiable, Codable, Sendable {
    public var id: UUID
    public var semester: String
    public var studentName: String
    public var className: String
    public var schoolName: String
    public var slots: [TimetableSlot]
    public var items: [DraftCourseItem]
    public var warnings: [String]
    
    public init(
        id: UUID = UUID(),
        semester: String = "2026-2027-1",
        studentName: String = "",
        className: String = "",
        schoolName: String = "",
        slots: [TimetableSlot] = [],
        items: [DraftCourseItem] = [],
        warnings: [String] = []
    ) {
        self.id = id
        self.semester = semester
        self.studentName = studentName
        self.className = className
        self.schoolName = schoolName
        self.slots = slots
        self.items = items
        self.warnings = warnings
    }
}

public struct LessonSession: Identifiable, Codable, Sendable {
    public var id: UUID
    public var courseId: UUID?
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var duration: TimeInterval
    public var audioFileName: String
    public var mode: RecordingMode
    public var status: LessonStatus
    public var marks: [TimeInterval]
    public var segments: [TranscriptSegment]
    public var notes: [LessonNote]
    public var qaPairs: [QAPair]
    public var summaryTopic: String
    
    public init(
        id: UUID = UUID(),
        courseId: UUID? = nil,
        title: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        duration: TimeInterval = 0,
        audioFileName: String = "",
        mode: RecordingMode = .realtime,
        status: LessonStatus = .recording,
        marks: [TimeInterval] = [],
        segments: [TranscriptSegment] = [],
        notes: [LessonNote] = [],
        qaPairs: [QAPair] = [],
        summaryTopic: String = ""
    ) {
        self.id = id
        self.courseId = courseId
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.audioFileName = audioFileName.isEmpty ? "\(id.uuidString).caf" : audioFileName
        self.mode = mode
        self.status = status
        self.marks = marks
        self.segments = segments
        self.notes = notes
        self.qaPairs = qaPairs
        self.summaryTopic = summaryTopic
    }
    
    public var fullTranscript: String {
        segments.map { $0.text }.joined(separator: "\n")
    }

    public var courseName: String {
        title
    }
}
