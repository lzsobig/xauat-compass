import Foundation

public enum RecordingMode: String, Codable, CaseIterable {
    case realtime = "realtime"
    case recordOnly = "recordOnly"
    
    public var title: String {
        switch self {
        case .realtime: return "实时转写"
        case .recordOnly: return "仅录音"
        }
    }
}

public enum LessonStatus: String, Codable {
    case recording = "recording"
    case paused = "paused"
    case interrupted = "interrupted"
    case completed = "completed"
    
    public var title: String {
        switch self {
        case .recording: return "录制中"
        case .paused: return "已暂停"
        case .interrupted: return "录音中断"
        case .completed: return "已完成"
        }
    }
}

public struct TranscriptSegment: Identifiable, Codable, Equatable {
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

public enum NoteStyle: String, Codable, CaseIterable {
    case detailedOutline = "detailedOutline"
    case keyPoints = "keyPoints"
    case examReview = "examReview"
    
    public var title: String {
        switch self {
        case .detailedOutline: return "详细纲要"
        case .keyPoints: return "核心要点"
        case .examReview: return "考试复习"
        }
    }
}

public struct LessonNote: Identifiable, Codable {
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

public struct QAPair: Identifiable, Codable {
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

public struct Course: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var teacher: String
    public var room: String
    public var colorHex: String
    public var createdAt: Date
    
    public init(id: UUID = UUID(), name: String, teacher: String = "", room: String = "", colorHex: String = "#0A84FF", createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.teacher = teacher
        self.room = room
        self.colorHex = colorHex
        self.createdAt = createdAt
    }
}

public struct TimetableSlot: Identifiable, Codable, Equatable {
    public var id: UUID
    public var courseName: String
    public var teacher: String
    public var room: String
    public var day: Int // 1 (Mon) - 7 (Sun)
    public var fromPeriod: Int // 1 - 11
    public var toPeriod: Int // 1 - 11
    public var weekFrom: Int
    public var weekTo: Int
    public var parity: String // "all", "odd", "even"
    
    public init(id: UUID = UUID(), courseName: String, teacher: String = "", room: String = "", day: Int, fromPeriod: Int, toPeriod: Int, weekFrom: Int = 1, weekTo: Int = 20, parity: String = "all") {
        self.id = id
        self.courseName = courseName
        self.teacher = teacher
        self.room = room
        self.day = day
        self.fromPeriod = fromPeriod
        self.toPeriod = toPeriod
        self.weekFrom = weekFrom
        self.weekTo = weekTo
        self.parity = parity
    }
}

public struct TimetableData: Codable {
    public var currentWeek: Int
    public var slots: [TimetableSlot]
    public var updatedAt: Date
    
    public init(currentWeek: Int = 1, slots: [TimetableSlot] = [], updatedAt: Date = Date()) {
        self.currentWeek = currentWeek
        self.slots = slots
        self.updatedAt = updatedAt
    }
}

public struct LessonSession: Identifiable, Codable {
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
}
