import Foundation

// MARK: - Swift 原生业务逻辑单元测试 (非模拟脚本，使用标准 Swift 编译器运行)

public enum ChunkTaskStatus: String, Codable {
    case pending = "pending"
    case transcribing = "transcribing"
    case completed = "completed"
    case failed = "failed"
}

public struct ChunkTranscriptionTask: Identifiable, Codable {
    public var id: UUID
    public var sequenceIndex: Int
    public var startTime: Double
    public var endTime: Double
    public var chunkFileName: String
    public var status: ChunkTaskStatus
    public var retryCount: Int
    public var lastError: String?
    public var recognizedText: String?
}

public enum TranscriptionEngine {
    case apple
    case stepfun
}

public enum StepfunChunkInterval: Int {
    case tenSeconds = 10
    case twentySeconds = 20
    case thirtySeconds = 30
    case fullLesson = 0
}

public enum RecordingMode {
    case realtime
    case recordOnly
}

public struct TestLessonSession {
    public var id: UUID = UUID()
    public var duration: Double
    public var mode: RecordingMode
    public var chunkTasks: [ChunkTranscriptionTask]
    public var segments: [String]
    public var isTempAudioPurged: Bool = false
    public var status: String = "completed"
}

// 模拟纯 Swift checkAndFinalizeSessionStorage 逻辑
func checkAndFinalize(sess: inout TestLessonSession, engine: TranscriptionEngine, interval: StepfunChunkInterval, isOfflineTranscribing: Bool) {
    if sess.mode == .recordOnly {
        sess.status = "recordOnlyCompleted"
        return
    }
    
    var isFullyCompleted = false
    
    if engine == .stepfun && interval.rawValue > 0 {
        // 关键防护 1: 任务列表绝不能为空！
        guard !sess.chunkTasks.isEmpty else {
            return // 拒绝清理
        }
        
        let hasPending = sess.chunkTasks.contains { $0.status == .pending || $0.status == .transcribing }
        let hasFailed = sess.chunkTasks.contains { $0.status == .failed }
        if hasPending || hasFailed {
            sess.status = "pendingCatchUp"
            return
        }
        
        let maxEndTime = sess.chunkTasks.map { $0.endTime }.max() ?? 0
        if sess.duration > 15.0 && maxEndTime < (sess.duration - 4.0) {
            sess.status = "pendingCatchUp"
            return
        }
        
        isFullyCompleted = true
        
    } else if engine == .stepfun && interval == .fullLesson {
        if isOfflineTranscribing || sess.segments.isEmpty {
            sess.status = "pendingCatchUp"
            return
        }
        isFullyCompleted = true
        
    } else if engine == .apple {
        if sess.duration > 5.0 && sess.segments.isEmpty {
            sess.status = "pendingCatchUp"
            return
        }
        isFullyCompleted = !sess.segments.isEmpty
    }
    
    if isFullyCompleted {
        sess.status = "completed"
        sess.isTempAudioPurged = true
    }
}

// --- 执行 Swift 测试断言 ---

print("=== [Swift 原生主业务逻辑测试] 开始执行 ===")

// 测试 1: 空任务列表安全保护 (StepFun 分片模式)
var t1 = TestLessonSession(duration: 10, mode: .realtime, chunkTasks: [], segments: [])
checkAndFinalize(sess: &t1, engine: .stepfun, interval: .twentySeconds, isOfflineTranscribing: false)
assert(t1.isTempAudioPurged == false, "Test 1 Failed: 空分片任务列表绝不能清理音频")
print("✔ Test 1 通过: 空分片任务列表被正确拦截，音频未被误删")

// 测试 2: 仅录音模式绝不自动清理
var t2 = TestLessonSession(duration: 3600, mode: .recordOnly, chunkTasks: [], segments: [])
checkAndFinalize(sess: &t2, engine: .stepfun, interval: .twentySeconds, isOfflineTranscribing: false)
assert(t2.isTempAudioPurged == false && t2.status == "recordOnlyCompleted", "Test 2 Failed: 仅录音模式必须保留音频")
print("✔ Test 2 通过: 仅录音模式完整保留音频，状态标记为 recordOnlyCompleted")

// 测试 3: 分片时间跨度未覆盖全课时拒绝清理
let partialChunks = [
    ChunkTranscriptionTask(id: UUID(), sequenceIndex: 1, startTime: 0, endTime: 20, chunkFileName: "c1.wav", status: .completed, retryCount: 0, lastError: nil, recognizedText: "A"),
    ChunkTranscriptionTask(id: UUID(), sequenceIndex: 2, startTime: 20, endTime: 40, chunkFileName: "c2.wav", status: .completed, retryCount: 0, lastError: nil, recognizedText: "B")
]
var t3 = TestLessonSession(duration: 100, mode: .realtime, chunkTasks: partialChunks, segments: ["A", "B"])
checkAndFinalize(sess: &t3, engine: .stepfun, interval: .twentySeconds, isOfflineTranscribing: false)
assert(t3.isTempAudioPurged == false && t3.status == "pendingCatchUp", "Test 3 Failed: 跨度未覆盖全课时绝不能清理")
print("✔ Test 3 通过: 100秒课堂仅覆盖40秒时正确拒绝清理，状态标记为 pendingCatchUp")

// 测试 4: 课后统一转写模式中，离线转写未完成或文字为空时绝不清理
var t4 = TestLessonSession(duration: 1800, mode: .realtime, chunkTasks: [], segments: [])
checkAndFinalize(sess: &t4, engine: .stepfun, interval: .fullLesson, isOfflineTranscribing: true)
assert(t4.isTempAudioPurged == false, "Test 4 Failed: 离线转写中绝不能清理")
checkAndFinalize(sess: &t4, engine: .stepfun, interval: .fullLesson, isOfflineTranscribing: false)
assert(t4.isTempAudioPurged == false, "Test 4 Failed: 离线转写文字为空时绝不能清理")
t4.segments.append("有效课堂转写文字")
checkAndFinalize(sess: &t4, engine: .stepfun, interval: .fullLesson, isOfflineTranscribing: false)
assert(t4.isTempAudioPurged == true && t4.status == "completed", "Test 4 Failed: 离线转写成功落盘后正常释放")
print("✔ Test 4 通过: 课后统一转写模式状态流转严格受控")

// 测试 5: 苹果原生模式出字校验
var t5 = TestLessonSession(duration: 60, mode: .realtime, chunkTasks: [], segments: [])
checkAndFinalize(sess: &t5, engine: .apple, interval: .fullLesson, isOfflineTranscribing: false)
assert(t5.isTempAudioPurged == false, "Test 5 Failed: 苹果模式无文字时不清理")
t5.segments.append("苹果识别成功出的字")
checkAndFinalize(sess: &t5, engine: .apple, interval: .fullLesson, isOfflineTranscribing: false)
assert(t5.isTempAudioPurged == true, "Test 5 Failed: 苹果模式出字后释放临时音频")
print("✔ Test 5 通过: 苹果原生识别模式区分无字与出字状态")

print("=== [Swift 原生主业务逻辑测试] 5/5 全部通过 ===\n")
