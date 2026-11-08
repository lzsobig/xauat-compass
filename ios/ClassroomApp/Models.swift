import Foundation

// MARK: - 录音模式与转写引擎

public enum RecordingMode: String, Codable, CaseIterable, Sendable {
    case realtime = "realtime"
    case recordOnly = "recordOnly"
    
    public var title: String {
        switch self {
        case .realtime: return "实时转写"
        case .recordOnly: return "仅录音 (不转写·纯保真)"
        }
    }
}

public enum TranscriptionEngine: String, Codable, CaseIterable, Sendable {
    case apple = "apple"
    case stepfun = "stepfun"
    
    public var title: String {
        switch self {
        case .apple: return "苹果原生语音识别 (免Key·系统输入法)"
        case .stepfun: return "阶跃星辰 ASR (云端高精·按Key)"
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
        case .apple: return "免Key/系统"
        case .stepfun: return "stepaudio-2.5-asr"
        }
    }
}

public enum StepfunChunkInterval: Int, Codable, CaseIterable, Sendable {
    case tenSeconds = 10
    case twentySeconds = 20
    case thirtySeconds = 30
    case fullLesson = 0
    
    public var title: String {
        switch self {
        case .tenSeconds: return "10 秒切片转写 (极速出字)"
        case .twentySeconds: return "20 秒切片转写 (推荐·语义完整)"
        case .thirtySeconds: return "30 秒切片转写 (段落更长)"
        case .fullLesson: return "课后统一转写 (录中静默)"
        }
    }
    
    public var shortTitle: String {
        switch self {
        case .tenSeconds: return "10秒切片"
        case .twentySeconds: return "20秒切片"
        case .thirtySeconds: return "30秒切片"
        case .fullLesson: return "课后转写"
        }
    }
}

// MARK: - 云端存储配置与状态

public enum AudioStorageMode: String, Codable, CaseIterable, Sendable {
    case cloudFirst = "cloudFirst"
    case cloudAndLocal = "cloudAndLocal"
    case localOnly = "localOnly"
    
    public var title: String {
        switch self {
        case .cloudFirst: return "云端优先 (省手机空间)"
        case .cloudAndLocal: return "云端 + 本地 (双重备份·推荐)"
        case .localOnly: return "仅本地存储 (离线可用·不上传)"
        }
    }
    
    public var detailDescription: String {
        switch self {
        case .cloudFirst:
            return "录音先存本地临时缓存，上传至 Cloudflare R2 并校验成功后自动释放本地空间；回放时按需云端秒级流式播放。"
        case .cloudAndLocal:
            return "本地保留完整音频供随时离线回放，同时后台自动压缩备份至云端，换设备或防误删两全其美。"
        case .localOnly:
            return "完全不向云端发送任何音频数据，仅在手机沙盒中保留，保护私密性，无网络开销。"
        }
    }
}

public enum StorageStatus: String, Codable, Sendable {
    case localOnly = "localOnly"
    case uploading = "uploading"
    case uploadFailed = "uploadFailed"
    case cloudVerified = "cloudVerified"
    case cloudOnly = "cloudOnly"
    
    public var title: String {
        switch self {
        case .localOnly: return "仅本机"
        case .uploading: return "正在备份至云端"
        case .uploadFailed: return "云端上传失败 (待重试)"
        case .cloudVerified: return "云端与本地已同步"
        case .cloudOnly: return "云端存储 (已省本地空间)"
        }
    }
}

// MARK: - 分片转写任务状态与模型

public enum ChunkTaskStatus: String, Codable, Sendable {
    case pending = "pending"           // 等待转写（录制完成或待重试）
    case transcribing = "transcribing" // 正在调用 ASR
    case completed = "completed"       // 转写成功，文字已落盘
    case failed = "failed"             // 转写失败（断网/超时/服务端错误）
    
    public var title: String {
        switch self {
        case .pending: return "排队中"
        case .transcribing: return "转写中"
        case .completed: return "成功"
        case .failed: return "失败"
        }
    }
}

public struct ChunkTranscriptionTask: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var sequenceIndex: Int
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var chunkFileName: String
    public var status: ChunkTaskStatus
    public var retryCount: Int
    public var lastError: String?
    public var recognizedText: String?
    
    public init(
        id: UUID = UUID(),
        sequenceIndex: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        chunkFileName: String,
        status: ChunkTaskStatus = .pending,
        retryCount: Int = 0,
        lastError: String? = nil,
        recognizedText: String? = nil
    ) {
        self.id = id
        self.sequenceIndex = sequenceIndex
        self.startTime = startTime
        self.endTime = endTime
        self.chunkFileName = chunkFileName
        self.status = status
        self.retryCount = retryCount
        self.lastError = lastError
        self.recognizedText = recognizedText
    }
}

public enum LessonStatus: String, Codable, Sendable {
    case recording = "recording"                     // 实时转写中
    case paused = "paused"                           // 已暂停
    case pendingCatchUp = "pendingCatchUp"           // 待补转写
    case transcriptionFailed = "transcriptionFailed" // 转写失败
    case completed = "completed"                     // 转写完成
    case recordOnlyCompleted = "recordOnlyCompleted" // 录音已保存
    case interrupted = "interrupted"                 // 录音中断
    
    public var title: String {
        switch self {
        case .recording: return "实时转写中"
        case .paused: return "已暂停"
        case .pendingCatchUp: return "待补转写"
        case .transcriptionFailed: return "转写失败"
        case .completed: return "转写完成"
        case .recordOnlyCompleted: return "录音已保存"
        case .interrupted: return "录音中断(待补转)"
        }
    }
}

// MARK: - 转录段落

public struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sequenceIndex: Int
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var isMarked: Bool
    
    public init(id: UUID = UUID(), sequenceIndex: Int = 0, startTime: TimeInterval, endTime: TimeInterval, text: String, isMarked: Bool = false) {
        self.id = id
        self.sequenceIndex = sequenceIndex
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.isMarked = isMarked
    }
    
    enum CodingKeys: String, CodingKey {
        case id, sequenceIndex, startTime, endTime, text, isMarked
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.sequenceIndex = try container.decodeIfPresent(Int.self, forKey: .sequenceIndex) ?? 0
        self.startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        self.endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        self.text = try container.decode(String.self, forKey: .text)
        self.isMarked = try container.decodeIfPresent(Bool.self, forKey: .isMarked) ?? false
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sequenceIndex, forKey: .sequenceIndex)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(text, forKey: .text)
        try container.encode(isMarked, forKey: .isMarked)
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
        case .examReview: return "考试复习"
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

public struct Course: Identifiable, Codable, Equatable, Sendable {
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

public struct TimetableSlot: Identifiable, Codable, Equatable, Sendable {
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

public struct TimetableData: Codable, Sendable {
    public var currentWeek: Int
    public var slots: [TimetableSlot]
    public var updatedAt: Date
    
    public init(currentWeek: Int = 1, slots: [TimetableSlot] = [], updatedAt: Date = Date()) {
        self.currentWeek = currentWeek
        self.slots = slots
        self.updatedAt = updatedAt
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
    
    // 分片转写任务与临时音频清理状态
    public var chunkTasks: [ChunkTranscriptionTask]
    public var isTempAudioPurged: Bool
    
    // 云存储与同步状态
    public var storageMode: AudioStorageMode
    public var storageStatus: StorageStatus
    public var remoteAudioKey: String?
    public var audioSize: Int64
    public var lastUploadError: String?
    
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
        summaryTopic: String = "",
        chunkTasks: [ChunkTranscriptionTask] = [],
        isTempAudioPurged: Bool = false,
        storageMode: AudioStorageMode = .cloudAndLocal,
        storageStatus: StorageStatus = .localOnly,
        remoteAudioKey: String? = nil,
        audioSize: Int64 = 0,
        lastUploadError: String? = nil
    ) {
        self.id = id
        self.courseId = courseId
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.audioFileName = audioFileName.isEmpty ? "\(id.uuidString).m4a" : audioFileName
        self.mode = mode
        self.status = status
        self.marks = marks
        self.segments = segments
        self.notes = notes
        self.qaPairs = qaPairs
        self.summaryTopic = summaryTopic
        self.chunkTasks = chunkTasks
        self.isTempAudioPurged = isTempAudioPurged
        self.storageMode = storageMode
        self.storageStatus = storageStatus
        self.remoteAudioKey = remoteAudioKey
        self.audioSize = audioSize
        self.lastUploadError = lastUploadError
    }
    
    enum CodingKeys: String, CodingKey {
        case id, courseId, title, startedAt, endedAt, duration, audioFileName, mode, status
        case marks, segments, notes, qaPairs, summaryTopic
        case chunkTasks, isTempAudioPurged
        case storageMode, storageStatus, remoteAudioKey, audioSize, lastUploadError
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.courseId = try container.decodeIfPresent(UUID.self, forKey: .courseId)
        self.title = try container.decode(String.self, forKey: .title)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        self.duration = try container.decode(TimeInterval.self, forKey: .duration)
        self.audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName) ?? "\(self.id.uuidString).m4a"
        self.mode = try container.decodeIfPresent(RecordingMode.self, forKey: .mode) ?? .realtime
        self.status = try container.decodeIfPresent(LessonStatus.self, forKey: .status) ?? .completed
        self.marks = try container.decodeIfPresent([TimeInterval].self, forKey: .marks) ?? []
        self.segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        self.notes = try container.decodeIfPresent([LessonNote].self, forKey: .notes) ?? []
        self.qaPairs = try container.decodeIfPresent([QAPair].self, forKey: .qaPairs) ?? []
        self.summaryTopic = try container.decodeIfPresent(String.self, forKey: .summaryTopic) ?? ""
        self.chunkTasks = try container.decodeIfPresent([ChunkTranscriptionTask].self, forKey: .chunkTasks) ?? []
        self.isTempAudioPurged = try container.decodeIfPresent(Bool.self, forKey: .isTempAudioPurged) ?? false
        
        self.storageMode = try container.decodeIfPresent(AudioStorageMode.self, forKey: .storageMode) ?? .cloudAndLocal
        self.storageStatus = try container.decodeIfPresent(StorageStatus.self, forKey: .storageStatus) ?? .localOnly
        self.remoteAudioKey = try container.decodeIfPresent(String.self, forKey: .remoteAudioKey)
        self.audioSize = try container.decodeIfPresent(Int64.self, forKey: .audioSize) ?? 0
        self.lastUploadError = try container.decodeIfPresent(String.self, forKey: .lastUploadError)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(courseId, forKey: .courseId)
        try container.encode(title, forKey: .title)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encode(duration, forKey: .duration)
        try container.encode(audioFileName, forKey: .audioFileName)
        try container.encode(mode, forKey: .mode)
        try container.encode(status, forKey: .status)
        try container.encode(marks, forKey: .marks)
        try container.encode(segments, forKey: .segments)
        try container.encode(notes, forKey: .notes)
        try container.encode(qaPairs, forKey: .qaPairs)
        try container.encode(summaryTopic, forKey: .summaryTopic)
        try container.encode(chunkTasks, forKey: .chunkTasks)
        try container.encode(isTempAudioPurged, forKey: .isTempAudioPurged)
        try container.encode(storageMode, forKey: .storageMode)
        try container.encode(storageStatus, forKey: .storageStatus)
        try container.encodeIfPresent(remoteAudioKey, forKey: .remoteAudioKey)
        try container.encode(audioSize, forKey: .audioSize)
        try container.encodeIfPresent(lastUploadError, forKey: .lastUploadError)
    }
    
    public var fullTranscript: String {
        segments.sorted { $0.startTime < $1.startTime }.map { $0.text }.joined(separator: "\n")
    }
}
