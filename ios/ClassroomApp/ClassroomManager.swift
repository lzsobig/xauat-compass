import AVFoundation
import Combine
import CoreMedia
import Foundation
import Speech
import SwiftUI

// MARK: - PCM 转 WAV 工具函数

public func pcmToWav(samples: [Int16], sampleRate: Int = 16000) -> Data {
    var data = Data()
    let byteRate = sampleRate * 2
    let dataSize = samples.count * 2
    let chunkSize = 36 + dataSize
    
    // RIFF
    data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
    var val32 = UInt32(chunkSize).littleEndian
    data.append(Data(bytes: &val32, count: 4))
    // WAVE
    data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
    
    // fmt subchunk
    data.append(contentsOf: [0x66, 0x6d, 0x74, 0x20])
    var subchunk1Size = UInt32(16).littleEndian
    data.append(Data(bytes: &subchunk1Size, count: 4))
    var audioFormat = UInt16(1).littleEndian // PCM
    data.append(Data(bytes: &audioFormat, count: 2))
    var numChannels = UInt16(1).littleEndian // Mono
    data.append(Data(bytes: &numChannels, count: 2))
    var sr = UInt32(sampleRate).littleEndian
    data.append(Data(bytes: &sr, count: 4))
    var br = UInt32(byteRate).littleEndian
    data.append(Data(bytes: &br, count: 4))
    var blockAlign = UInt16(2).littleEndian
    data.append(Data(bytes: &blockAlign, count: 2))
    var bitsPerSample = UInt16(16).littleEndian
    data.append(Data(bytes: &bitsPerSample, count: 2))
    
    // data subchunk
    data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
    var ds = UInt32(dataSize).littleEndian
    data.append(Data(bytes: &ds, count: 4))
    
    samples.withUnsafeBufferPointer { ptr in
        data.append(Data(buffer: ptr))
    }
    return data
}

// MARK: - 语音切片文字平滑拼接与去重
public func stitchTranscripts(previous: String, current: String) -> String {
    let punctChars = "，。！？、；： \t\n"
    var pCore = previous.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = pCore.last, punctChars.contains(last) {
        pCore.removeLast()
    }
    var cCore = current.trimmingCharacters(in: .whitespacesAndNewlines)
    while let first = cCore.first, punctChars.contains(first) {
        cCore.removeFirst()
    }
    
    guard !pCore.isEmpty else { return current }
    guard !cCore.isEmpty else { return "" }
    
    let pChars = Array(pCore)
    let cChars = Array(cCore)
    
    // 在 2 到 14 个字符范围内寻找前一句尾部与后一句头部的重叠匹配
    let maxMatchLen = min(14, min(pChars.count, cChars.count))
    if maxMatchLen >= 2 {
        for len in stride(from: maxMatchLen, through: 2, by: -1) {
            let tail = String(pChars.suffix(len))
            let head = String(cChars.prefix(len))
            
            if tail == head {
                if let range = current.range(of: head) {
                    var remaining = String(current[range.upperBound...])
                    while let first = remaining.first, punctChars.contains(first) {
                        remaining.removeFirst()
                    }
                    return remaining
                }
            }
        }
    }
    return current
}

private final class AudioCapture {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var totalFrames: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100
    private var writeFailed = false
    
    // 阶跃 ASR 实时分段切片缓冲区 (重采样到 16kHz 16-bit 单声道)
    private var sliceSamples: [Int16] = []
    private var sliceStepAccumulator: Double = 0

    // VAD 动态静音停顿检测（陈逸飞自主截断核心逻辑）
    private var consecutiveSilenceFrames: Int = 0
    private let silenceRmsThreshold: Float = 0.015 // 归一化静音振幅门限 (约 -36dB)

    init(file: AVAudioFile, sampleRate: Double) {
        self.file = file
        self.sampleRate = sampleRate
    }

    func append(_ buffer: AVAudioPCMBuffer) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        guard let file = file, !writeFailed else { return nil }
        do {
            try file.write(from: buffer)
            totalFrames += AVAudioFramePosition(buffer.frameLength)
            speechRequest?.append(buffer)
            
            // 重采样至 16kHz 单声道 PCM 以供阶跃 ASR 分段切片
            if let floatChannelData = buffer.floatChannelData {
                let channel0 = floatChannelData[0]
                let frameCount = Int(buffer.frameLength)
                
                // 实时计算当前音频帧的 RMS 能量
                var sumSquares: Float = 0
                for f in 0..<frameCount {
                    let s = channel0[f]
                    sumSquares += s * s
                }
                let rms = frameCount > 0 ? sqrt(sumSquares / Float(frameCount)) : 0
                
                if rms < silenceRmsThreshold {
                    consecutiveSilenceFrames += frameCount
                } else {
                    consecutiveSilenceFrames = 0
                }
                
                let step = sampleRate / 16000.0
                var idx: Double = sliceStepAccumulator
                while idx < Double(frameCount) {
                    let sampleIdx = Int(idx)
                    let rawFloat = channel0[sampleIdx]
                    let clamped = max(-1.0, min(1.0, rawFloat))
                    let int16Sample = Int16(clamped * 32767.0)
                    sliceSamples.append(int16Sample)
                    idx += step
                }
                sliceStepAccumulator = idx - Double(frameCount)
            }
            return nil
        } catch {
            writeFailed = true
            return error
        }
    }

    var consecutiveSilenceSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        guard sampleRate > 0 else { return 0 }
        return Double(consecutiveSilenceFrames) / sampleRate
    }

    func attachSpeechRequest(_ req: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        defer { lock.unlock() }
        speechRequest?.endAudio()
        speechRequest = req
    }

    // 提取当前切片 WAV 数据，同时保留 keepOverlapSeconds（默认 1.5 秒）音频作为下一段的开头，防止切片边界漏字
    func takeCurrentSliceWavData(keepOverlapSeconds: Double = 1.5) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !sliceSamples.isEmpty else { return nil }
        let samples = sliceSamples
        
        let overlapCount = Int(keepOverlapSeconds * 16000)
        if keepOverlapSeconds > 0 && samples.count > overlapCount + 8000 {
            let overlapSamples = Array(samples.suffix(overlapCount))
            sliceSamples = overlapSamples
        } else {
            sliceSamples.removeAll(keepingCapacity: true)
        }
        consecutiveSilenceFrames = 0
        return pcmToWav(samples: samples, sampleRate: 16000)
    }

    var recordedDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard sampleRate > 0 else { return 0 }
        return Double(totalFrames) / sampleRate
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        speechRequest?.endAudio()
        speechRequest = nil
        file = nil
        sliceSamples.removeAll()
        consecutiveSilenceFrames = 0
    }
}

// MARK: - 主业务管理器

@MainActor
public final class ClassroomManager: ObservableObject {
    @Published public var courses: [Course] = []
    @Published public var timetable: TimetableData = TimetableData()
    @Published public var sessions: [LessonSession] = []
    @Published public var currentSession: LessonSession?
    @Published public var isRecording: Bool = false
    @Published public var isPaused: Bool = false
    @Published public var recordingElapsed: TimeInterval = 0
    @Published public var suggestedCourse: Course?
    @Published public var suggestionReason: String = "根据课表智能推荐"
    @Published public var errorMessage: String = ""
    
    // AI 大模型与转写配置（敏感密钥由 iOS Keychain 统一保管）
    @Published public var llmBaseURL: String {
        didSet { UserDefaults.standard.set(llmBaseURL, forKey: "llmBaseURL") }
    }
    @Published public var llmModel: String {
        didSet { UserDefaults.standard.set(llmModel, forKey: "llmModel") }
    }
    @Published public var llmApiKey: String {
        didSet {
            KeychainHelper.save(key: "llmApiKey", value: llmApiKey)
        }
    }
    @Published public var stepfunBaseURL: String {
        didSet { UserDefaults.standard.set(stepfunBaseURL, forKey: "stepfunBaseURL") }
    }
    @Published public var stepfunAsrModel: String {
        didSet { UserDefaults.standard.set(stepfunAsrModel, forKey: "stepfunAsrModel") }
    }
    @Published public var stepfunApiKey: String {
        didSet {
            KeychainHelper.save(key: "stepfunApiKey", value: stepfunApiKey)
        }
    }
    
    // 转录引擎选择 (苹果原生 / 阶跃星辰 ASR)
    @Published public var transcriptionEngine: TranscriptionEngine {
        didSet { UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: "transcriptionEngine") }
    }
    
    // 阶跃 ASR 切片转录周期 (10秒 / 20秒 / 30秒 / 课后)
    @Published public var stepfunChunkInterval: StepfunChunkInterval {
        didSet {
            UserDefaults.standard.set(stepfunChunkInterval.rawValue, forKey: "stepfunChunkInterval")
            UserDefaults.standard.set(true, forKey: "stepfunChunkInterval_set")
        }
    }
    @Published public var isChunkTranscribing: Bool = false

    // 云端存储配置绑定
    public var r2StorageMode: AudioStorageMode {
        get { R2UploadManager.shared.storageMode }
        set {
            R2UploadManager.shared.storageMode = newValue
            objectWillChange.send()
        }
    }
    public var r2AllowCellular: Bool {
        get { R2UploadManager.shared.allowCellularUpload }
        set {
            R2UploadManager.shared.allowCellularUpload = newValue
            objectWillChange.send()
        }
    }
    public var r2WorkerBaseURL: String {
        get { R2UploadManager.shared.workerBaseURL }
        set {
            R2UploadManager.shared.workerBaseURL = newValue
            objectWillChange.send()
        }
    }
    
    public func downloadCloudAudio(for session: LessonSession) async {
        let dest = audioURL(for: session)
        try? await R2UploadManager.shared.downloadAudioToLocal(session: session, destinationURL: dest)
    }

    // 播放器状态 (支持本地 AVAudioPlayer 与云端 AVPlayer 流式播放)
    @Published public var isPlayingAudio: Bool = false
    @Published public var playbackTime: TimeInterval = 0
    @Published public var playbackDuration: TimeInterval = 0
    @Published public var playbackRate: Float = 1.0
    @Published public var playingSessionId: UUID?
    
    // AI 处理状态
    @Published public var isTranscribingOffline: Bool = false
    @Published public var isGeneratingNotes: Bool = false
    @Published public var isAskingQA: Bool = false

    private let storageRoot: URL
    private let engine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var capture: AudioCapture?
    private var speechTask: SFSpeechRecognitionTask?
    private var lastChunkTime: TimeInterval = 0
    private var currentChunkIndex: Int = 0
    private var speechEpoch = UUID()
    private var speechStartedAt: Date?
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var streamingPlayer: AVPlayer?
    private var streamingTimeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storageRoot = appSupport.appendingPathComponent("ClassroomRecordings", isDirectory: true)
        
        // 读取 AI 配置 (不内置任何真实密钥)
        self.llmBaseURL = UserDefaults.standard.string(forKey: "llmBaseURL") ?? "https://tokenrhythm.studio/v1"
        self.llmModel = UserDefaults.standard.string(forKey: "llmModel") ?? "deepseek-v4.1-flash-1017"
        
        // 安全迁移：从 UserDefaults 迁移至 iOS Keychain 并清除 UserDefaults 中的明文残留
        if let oldLLMKey = UserDefaults.standard.string(forKey: "llmApiKey"), !oldLLMKey.isEmpty {
            KeychainHelper.save(key: "llmApiKey", value: oldLLMKey)
            UserDefaults.standard.removeObject(forKey: "llmApiKey")
        }
        self.llmApiKey = KeychainHelper.get(key: "llmApiKey") ?? ""
        
        self.stepfunBaseURL = UserDefaults.standard.string(forKey: "stepfunBaseURL") ?? "https://api.stepfun.com/v1"
        self.stepfunAsrModel = UserDefaults.standard.string(forKey: "stepfunAsrModel") ?? "stepaudio-2.5-asr"
        
        if let oldStepKey = UserDefaults.standard.string(forKey: "stepfunApiKey"), !oldStepKey.isEmpty {
            KeychainHelper.save(key: "stepfunApiKey", value: oldStepKey)
            UserDefaults.standard.removeObject(forKey: "stepfunApiKey")
        }
        self.stepfunApiKey = KeychainHelper.get(key: "stepfunApiKey") ?? ""
        
        let savedEngine = UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "apple"
        self.transcriptionEngine = TranscriptionEngine(rawValue: savedEngine) ?? .apple
        
        let isIntervalSet = UserDefaults.standard.bool(forKey: "stepfunChunkInterval_set")
        if isIntervalSet {
            let savedIntervalVal = UserDefaults.standard.integer(forKey: "stepfunChunkInterval")
            self.stepfunChunkInterval = StepfunChunkInterval(rawValue: savedIntervalVal) ?? .twentySeconds
        } else {
            self.stepfunChunkInterval = .twentySeconds
        }

        try? FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        
        loadData()
        recoverInterruptedSessions()
        migrateLegacyRecordings()
        updateCourseSuggestion()
        setupInterruptionObserver()
    }
    
    public func resetAIDefaults() {
        self.llmBaseURL = "https://tokenrhythm.studio/v1"
        self.llmModel = "deepseek-v4.1-flash-1017"
        self.stepfunBaseURL = "https://api.stepfun.com/v1"
        self.stepfunAsrModel = "stepaudio-2.5-asr"
        self.llmApiKey = ""
        self.stepfunApiKey = ""
        KeychainHelper.delete(key: "llmApiKey")
        KeychainHelper.delete(key: "stepfunApiKey")
    }
    
    // MARK: - 持久化与文件管理
    
    private var coursesURL: URL { storageRoot.appendingPathComponent("courses.json") }
    private var timetableURL: URL { storageRoot.appendingPathComponent("timetable.json") }
    private var sessionsURL: URL { storageRoot.appendingPathComponent("sessions.json") }
    
    public func rawAudioURL(for session: LessonSession) -> URL {
        storageRoot.appendingPathComponent("raw_\(session.id.uuidString).caf")
    }

    public func audioURL(for session: LessonSession) -> URL {
        storageRoot.appendingPathComponent(session.audioFileName)
    }

    public func chunksFolder(for sessionId: UUID) -> URL {
        storageRoot.appendingPathComponent("chunks").appendingPathComponent(sessionId.uuidString)
    }

    public func chunkFileURL(sessionId: UUID, fileName: String) -> URL {
        chunksFolder(for: sessionId).appendingPathComponent(fileName)
    }

    public func appendChunkTask(_ task: ChunkTranscriptionTask, to sessionId: UUID) {
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            if !sessions[idx].chunkTasks.contains(where: { $0.id == task.id || $0.sequenceIndex == task.sequenceIndex }) {
                sessions[idx].chunkTasks.append(task)
                if currentSession?.id == sessionId {
                    currentSession?.chunkTasks = sessions[idx].chunkTasks
                }
                saveSessions()
            }
        }
    }

    public func updateChunkTask(sessionId: UUID, taskId: UUID, mutate: (inout ChunkTranscriptionTask) -> Void) {
        if let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
           let tIdx = sessions[sIdx].chunkTasks.firstIndex(where: { $0.id == taskId }) {
            mutate(&sessions[sIdx].chunkTasks[tIdx])
            if currentSession?.id == sessionId {
                currentSession?.chunkTasks = sessions[sIdx].chunkTasks
            }
            saveSessions()
        }
    }

    private func loadData() {
        let decoder = JSONDecoder()
        
        if let data = try? Data(contentsOf: timetableURL), let loaded = try? decoder.decode(TimetableData.self, from: data), !loaded.slots.isEmpty {
            self.timetable = loaded
        } else {
            let defaults = TimetableEngine.defaultSlots()
            self.timetable = TimetableData(currentWeek: 10, slots: defaults, updatedAt: Date())
            saveTimetable()
        }
        
        // 关键修复：只要 courses.json 存在且能正确解码，必须完整保留用户课程，无论课程数量是多少 (彻底移除 loaded.count > 4)
        if let data = try? Data(contentsOf: coursesURL), let loaded = try? decoder.decode([Course].self, from: data) {
            self.courses = loaded
        } else {
            var uniqueCourses: [String: Course] = [:]
            let colors = ["#007AFF", "#34C759", "#FF9500", "#AF52DE", "#FF2D55", "#5856D6", "#00C7BE", "#32ADE6"]
            var idx = 0
            for slot in TimetableEngine.defaultSlots() {
                if uniqueCourses[slot.courseName] == nil {
                    uniqueCourses[slot.courseName] = Course(
                        name: slot.courseName,
                        teacher: slot.teacher,
                        room: slot.room,
                        colorHex: colors[idx % colors.count]
                    )
                    idx += 1
                }
            }
            self.courses = Array(uniqueCourses.values).sorted { $0.name < $1.name }
            saveCourses()
        }
        
        if let data = try? Data(contentsOf: sessionsURL), let loaded = try? decoder.decode([LessonSession].self, from: data) {
            self.sessions = loaded.sorted { $0.startedAt > $1.startedAt }
        }
    }

    public func saveCourses() {
        if let data = try? JSONEncoder().encode(courses) {
            try? data.write(to: coursesURL, options: .atomic)
        }
    }

    public func saveTimetable() {
        if let data = try? JSONEncoder().encode(timetable) {
            try? data.write(to: timetableURL, options: .atomic)
        }
    }

    public func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: sessionsURL, options: .atomic)
        }
    }
    
    // MARK: - 课程推测更新
    
    public func updateCourseSuggestion() {
        let (found, reason) = CourseSuggester.suggestCourse(
            now: Date(),
            timetable: timetable,
            courses: courses,
            history: sessions
        )
        self.suggestedCourse = found
        self.suggestionReason = reason
    }
    
    // MARK: - 异常退出恢复与旧数据兼容
    
    private func recoverInterruptedSessions() {
        var modified = false
        for i in 0..<sessions.count {
            if sessions[i].status == .recording || sessions[i].status == .paused {
                sessions[i].status = .interrupted
                sessions[i].endedAt = Date()
                let url = audioURL(for: sessions[i])
                if FileManager.default.fileExists(atPath: url.path) {
                    if let file = try? AVAudioFile(forReading: url) {
                        let dur = Double(file.length) / file.fileFormat.sampleRate
                        sessions[i].duration = dur
                    }
                }
                modified = true
            }
            
            // 恢复崩溃或被切后台时处于 transcribing 的分片任务为 pending
            var sessionHasIncomplete = false
            for cIdx in 0..<sessions[i].chunkTasks.count {
                if sessions[i].chunkTasks[cIdx].status == .transcribing {
                    sessions[i].chunkTasks[cIdx].status = .pending
                    modified = true
                }
                if sessions[i].chunkTasks[cIdx].status == .pending || sessions[i].chunkTasks[cIdx].status == .failed {
                    sessionHasIncomplete = true
                }
            }
            
            if sessionHasIncomplete && sessions[i].status != .recording && sessions[i].status != .paused {
                sessions[i].status = .pendingCatchUp
                modified = true
            } else if !sessionHasIncomplete && sessions[i].mode == .realtime && !sessions[i].chunkTasks.isEmpty && !sessions[i].isTempAudioPurged && sessions[i].status != .recording {
                // 如果重启时发现该课堂所有分片皆已成功转写，自动清理残留临时音频
                let mainAudioURL = audioURL(for: sessions[i])
                try? FileManager.default.removeItem(at: mainAudioURL)
                let folder = chunksFolder(for: sessions[i].id)
                try? FileManager.default.removeItem(at: folder)
                sessions[i].isTempAudioPurged = true
                sessions[i].status = .completed
                modified = true
            }
            
            if sessions[i].storageStatus == .uploading {
                sessions[i].storageStatus = .uploadFailed
                modified = true
            }
        }
        if modified { saveSessions() }
    }
    
    private func migrateLegacyRecordings() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: storageRoot, includingPropertiesForKeys: nil) else { return }
        
        struct LegacyRecord: Codable {
            let id: UUID
            let date: Date
            var title: String
            var transcript: String?
            var marks: [TimeInterval]?
        }
        
        var modified = false
        for f in files where f.pathExtension == "json" && f.lastPathComponent != "courses.json" && f.lastPathComponent != "timetable.json" && f.lastPathComponent != "sessions.json" {
            guard let data = try? Data(contentsOf: f),
                  let legacy = try? JSONDecoder().decode(LegacyRecord.self, from: data) else { continue }
            
            if !sessions.contains(where: { $0.id == legacy.id }) {
                let cafURL = storageRoot.appendingPathComponent("\(legacy.id.uuidString).caf")
                var duration: TimeInterval = 0
                if let file = try? AVAudioFile(forReading: cafURL) {
                    duration = Double(file.length) / file.fileFormat.sampleRate
                }
                
                var segments: [TranscriptSegment] = []
                if let t = legacy.transcript, !t.isEmpty {
                    let lines = t.components(separatedBy: "\n").filter { !$0.isEmpty }
                    for (idx, line) in lines.enumerated() {
                        let start = TimeInterval(idx * 5)
                        segments.append(TranscriptSegment(sequenceIndex: idx, startTime: start, endTime: start + 5, text: line))
                    }
                }
                
                let restored = LessonSession(
                    id: legacy.id,
                    title: legacy.title,
                    startedAt: legacy.date,
                    endedAt: legacy.date.addingTimeInterval(duration),
                    duration: duration,
                    audioFileName: "\(legacy.id.uuidString).caf",
                    mode: .realtime,
                    status: .completed,
                    marks: legacy.marks ?? [],
                    segments: segments
                )
                sessions.append(restored)
                modified = true
            }
        }
        if modified { saveSessions() }
    }
    
    private func setupInterruptionObserver() {
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                guard let self = self, let userInfo = notification.userInfo,
                      let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                
                if type == .began {
                    if self.isRecording && !self.isPaused {
                        self.pauseRecording()
                    }
                    if self.isPlayingAudio {
                        self.pauseAudio()
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 课堂录制控制
    
    public func startRecording(course: Course?, mode: RecordingMode) async {
        guard !isRecording else { return }
        errorMessage = ""
        
        let audioSession = AVAudioSession.sharedInstance()
        let micGranted = await withCheckedContinuation { continuation in
            audioSession.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard micGranted else {
            errorMessage = "请在系统「设置」中允许建大课堂录音使用麦克风"
            return
        }
        
        // 权限判定：仅当使用苹果原生语音识别且为实时模式时，才检查 Apple Speech 权限
        var effectiveMode = mode
        if mode == .realtime && transcriptionEngine == .apple {
            let speechStatus = SFSpeechRecognizer.authorizationStatus()
            if speechStatus == .notDetermined {
                let speechGranted = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
                }
                if !speechGranted {
                    effectiveMode = .recordOnly
                    errorMessage = "系统语音识别权限被拒绝，已自动切换为「仅录音模式」，确保音频完整保存"
                }
            } else if speechStatus != .authorized {
                effectiveMode = .recordOnly
                errorMessage = "系统语音识别权限未开启，已自动切换为「仅录音模式」，确保音频完整保存"
            }
        }
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let dateStr = formatter.string(from: Date())
        let courseName = course?.name ?? "未归档"
        let defaultTitle = "\(courseName) - \(dateStr)课堂"
        
        let newSession = LessonSession(
            courseId: course?.id,
            title: defaultTitle,
            startedAt: Date(),
            mode: effectiveMode,
            status: .recording,
            storageMode: R2UploadManager.shared.storageMode,
            storageStatus: .localOnly
        )
        
        do {
            audioPlayer?.stop()
            streamingPlayer?.pause()
            isPlayingAudio = false
            
            try audioSession.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
            
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 && format.channelCount > 0 else {
                errorMessage = "麦克风输入格式不可用"
                return
            }
            
            // 严谨工程架构：录制流实时写入原生 CAF 容器，彻底消除因突发断电断网导致的 MP4 MOOV 损坏隐患
            let rawURL = rawAudioURL(for: newSession)
            if FileManager.default.fileExists(atPath: rawURL.path) {
                try? FileManager.default.removeItem(at: rawURL)
            }
            let file = try AVAudioFile(forWriting: rawURL, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            
            let sink = AudioCapture(file: file, sampleRate: format.sampleRate)
            self.capture = sink
            self.currentChunkIndex = 0
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                if let err = sink.append(buffer) {
                    DispatchQueue.main.async {
                        self?.errorMessage = "音频写入失败：\(err.localizedDescription)"
                    }
                }
            }
            
            try engine.start()
            
            self.currentSession = newSession
            self.sessions.insert(newSession, at: 0)
            self.saveSessions()
            self.isRecording = true
            self.isPaused = false
            self.recordingElapsed = 0
            self.lastChunkTime = 0
            
            // 实时苹果原生引擎启动
            if effectiveMode == .realtime && transcriptionEngine == .apple {
                startSpeechRecognition()
            }
            
            // 录音主计时器与阶跃 ASR 动态分片轮询
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, self.isRecording, !self.isPaused else { return }
                    if let cap = self.capture {
                        self.recordingElapsed = cap.recordedDuration
                        self.currentSession?.duration = self.recordingElapsed
                    }
                    
                    // 只有在【实时模式】且【阶跃引擎】且【切片间隔 > 0】时才切片转录
                    if self.currentSession?.mode == .realtime && self.transcriptionEngine == .stepfun && self.stepfunChunkInterval.rawValue > 0 {
                        let targetInterval = Double(self.stepfunChunkInterval.rawValue)
                        let chunkElapsed = self.recordingElapsed - self.lastChunkTime
                        
                        // 弹性自主截断窗口：目标周期前 5 秒开始探测语音停顿（例如 20s 周期在 15s~23s 内探测）
                        let minFlexTime = max(6.0, targetInterval - 5.0)
                        let maxHardTimeout = targetInterval + 3.0
                        
                        let silenceSecs = self.capture?.consecutiveSilenceSeconds ?? 0
                        let isSentenceEnded = silenceSecs >= 0.35 // 停顿 350ms 判定为一句话讲完
                        let canAutonomousCut = (chunkElapsed >= minFlexTime && isSentenceEnded)
                        let isForceTimeout = (chunkElapsed >= maxHardTimeout)
                        
                        if canAutonomousCut || isForceTimeout {
                            self.currentChunkIndex += 1
                            let chunkIdx = self.currentChunkIndex
                            let chunkStart = self.lastChunkTime
                            let chunkEnd = self.recordingElapsed
                            self.lastChunkTime = self.recordingElapsed
                            
                            // 保留 1.5 秒重叠音频供下一个切片，确保字词发音绝不被硬切断
                            if let wavData = self.capture?.takeCurrentSliceWavData(keepOverlapSeconds: 1.5), wavData.count > 44 + 8000 {
                                guard let targetId = self.currentSession?.id else { return }
                                
                                let chunkFileName = "chunk_\(chunkIdx).wav"
                                let folder = self.chunksFolder(for: targetId)
                                do {
                                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                    let chunkPath = folder.appendingPathComponent(chunkFileName)
                                    try wavData.write(to: chunkPath, options: .atomic)
                                    
                                    let task = ChunkTranscriptionTask(
                                        sequenceIndex: chunkIdx,
                                        startTime: chunkStart,
                                        endTime: chunkEnd,
                                        chunkFileName: chunkFileName,
                                        status: .pending
                                    )
                                    self.appendChunkTask(task, to: targetId)
                                    Task {
                                        await self.processChunkTask(sessionId: targetId, task: task)
                                    }
                                } catch {
                                    self.errorMessage = "音频切片写入失败：\(error.localizedDescription)"
                                    print("[AudioWriteError] 分片 \(chunkIdx) 写入沙盒失败: \(error)")
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            capture?.close()
            capture = nil
            engine.inputNode.removeTap(onBus: 0)
            try? audioSession.setActive(false)
            errorMessage = "启动录音失败：\(error.localizedDescription)"
        }
    }
    

    // MARK: - 分片转写任务执行与本地存储自动清理

    /// 真正的 async/await 顺序分片处理
    @discardableResult
    public func processChunkTask(sessionId: UUID, task: ChunkTranscriptionTask) async -> Bool {
        guard let sess = self.sessions.first(where: { $0.id == sessionId }) else { return false }
        guard let currentTask = sess.chunkTasks.first(where: { $0.id == task.id }) else { return false }
        if currentTask.status == .completed { return true }
        
        self.updateChunkTask(sessionId: sessionId, taskId: task.id) {
            $0.status = .transcribing
            $0.lastError = nil
        }
        self.isChunkTranscribing = true
        
        let chunkURL = self.chunkFileURL(sessionId: sessionId, fileName: task.chunkFileName)
        guard FileManager.default.fileExists(atPath: chunkURL.path),
              let audioData = try? Data(contentsOf: chunkURL),
              audioData.count > 44 + 8000 else {
            self.updateChunkTask(sessionId: sessionId, taskId: task.id) {
                $0.status = .failed
                $0.lastError = "分片音频数据文件不存在或损坏"
            }
            self.isChunkTranscribing = false
            return false
        }
        
        let lastText = sess.segments.last?.text ?? ""
        let promptSnippet = String(lastText.suffix(40))
        
        do {
            let transcribed = try await self.callStepFunASR(audioData: audioData, prompt: promptSnippet)
            let stitched = stitchTranscripts(previous: lastText, current: transcribed)
            let clean = stitched.trimmingCharacters(in: .whitespacesAndNewlines)
            
            self.isChunkTranscribing = false
            self.updateChunkTask(sessionId: sessionId, taskId: task.id) {
                $0.status = .completed
                $0.recognizedText = clean
                $0.lastError = nil
            }
            
            if !clean.isEmpty {
                let seg = TranscriptSegment(
                    sequenceIndex: task.sequenceIndex,
                    startTime: task.startTime,
                    endTime: task.endTime,
                    text: clean
                )
                self.insertAndSortSegment(segment: seg, targetSessionId: sessionId)
            }
            
            // 只有转写确认成功后，才安全删除该分片本地临时文件
            try? FileManager.default.removeItem(at: chunkURL)
            
            // 核验整堂课是否所有分片全部完成
            self.checkAndFinalizeSessionStorage(sessionId: sessionId)
            return true
        } catch {
            self.isChunkTranscribing = false
            self.updateChunkTask(sessionId: sessionId, taskId: task.id) {
                $0.status = .failed
                $0.retryCount += 1
                $0.lastError = error.localizedDescription
            }
            // 断网或异常：chunkURL 音频严禁删除！保留在本地供后续自动或手动补转写
            if let sIdx = self.sessions.firstIndex(where: { $0.id == sessionId }) {
                if self.sessions[sIdx].status != .recording && self.sessions[sIdx].status != .paused {
                    let failedCount = self.sessions[sIdx].chunkTasks.filter { $0.status == .failed }.count
                    self.sessions[sIdx].status = (failedCount >= 3) ? .transcriptionFailed : .pendingCatchUp
                    self.saveSessions()
                }
            }
            return false
        }
    }

    /// 核心存储终结判断：严格区分转录引擎与模式，只有确实覆盖整节录音、全部转写成功并可靠落盘后，才在实时模式下安全清理临时录音
    public func checkAndFinalizeSessionStorage(sessionId: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let sess = sessions[idx]
        
        // 1. 录音或暂停中不执行终结清理
        if sess.status == .recording || sess.status == .paused { return }
        
        // 2. 仅录音模式绝不自动清理任何录音！
        if sess.mode == .recordOnly {
            sessions[idx].status = .recordOnlyCompleted
            saveSessions()
            return
        }
        
        // 3. 严格引擎区分与完成度判定
        var isFullyCompleted = false
        
        if transcriptionEngine == .stepfun && stepfunChunkInterval.rawValue > 0 {
            // Case A: 阶跃星辰实时分片 ASR 模式
            // 规则：任务列表绝不能为空！必须至少有一个分片任务！
            guard !sess.chunkTasks.isEmpty else {
                print("[StorageGuard] 分片任务列表为空，绝不代表转写完成，拒绝清理音频。")
                return
            }
            
            let hasPendingOrTranscribing = sess.chunkTasks.contains { $0.status == .pending || $0.status == .transcribing }
            let failedTasks = sess.chunkTasks.filter { $0.status == .failed }
            
            if hasPendingOrTranscribing {
                sessions[idx].status = .pendingCatchUp
                saveSessions()
                return
            }
            
            if !failedTasks.isEmpty {
                // 有失败分片，保留音频供补转写
                sessions[idx].status = (failedTasks.count >= 3) ? .transcriptionFailed : .pendingCatchUp
                saveSessions()
                return
            }
            
            // 全部分片均为 completed，进一步核查时间跨度覆盖度（杜绝只录了开头漏了结尾）
            let maxEndTime = sess.chunkTasks.map { $0.endTime }.max() ?? 0
            if sess.duration > 15.0 && maxEndTime < (sess.duration - 4.0) {
                print("[StorageGuard] 分片时间跨度(\(maxEndTime)s) 未完整覆盖课堂时长(\(sess.duration)s)，拒绝清理。")
                sessions[idx].status = .pendingCatchUp
                saveSessions()
                return
            }
            
            isFullyCompleted = true
            
        } else if transcriptionEngine == .stepfun && stepfunChunkInterval == .fullLesson {
            // Case B: 阶跃星辰课后统一转写模式
            // 规则：离线转写不能正在运行中，且必须已有有效转写段落落盘
            if isTranscribingOffline {
                sessions[idx].status = .pendingCatchUp
                saveSessions()
                return
            }
            
            if sess.segments.isEmpty {
                // 尚未转写或离线转写失败，绝不清理音频
                sessions[idx].status = .pendingCatchUp
                saveSessions()
                return
            }
            
            isFullyCompleted = true
            
        } else if transcriptionEngine == .apple {
            // Case C: 苹果原生识别模式
            // 规则：课堂已结束，且转写文字不为空
            if sess.duration > 5.0 && sess.segments.isEmpty {
                // 苹果识别没有出字，保留音频供课后转写
                sessions[idx].status = .pendingCatchUp
                saveSessions()
                return
            }
            
            isFullyCompleted = !sess.segments.isEmpty
        }
        
        // 4. 终结清理执行（必须满足确实全部完成且处于 realtime 模式）
        if isFullyCompleted {
            sessions[idx].status = .completed
            
            if sess.mode == .realtime && !sessions[idx].isTempAudioPurged {
                let mainAudioURL = audioURL(for: sess)
                let rawURL = rawAudioURL(for: sess)
                let chunkFolder = chunksFolder(for: sessionId)
                
                // 真实删除文件并检验结果
                if FileManager.default.fileExists(atPath: mainAudioURL.path) {
                    try? FileManager.default.removeItem(at: mainAudioURL)
                }
                if FileManager.default.fileExists(atPath: rawURL.path) {
                    try? FileManager.default.removeItem(at: rawURL)
                }
                if FileManager.default.fileExists(atPath: chunkFolder.path) {
                    try? FileManager.default.removeItem(at: chunkFolder)
                }
                
                // 严谨校验：只有在文件确实已从磁盘消失时，才标记 isTempAudioPurged = true
                if !FileManager.default.fileExists(atPath: mainAudioURL.path) && !FileManager.default.fileExists(atPath: rawURL.path) {
                    sessions[idx].isTempAudioPurged = true
                    print("[Storage] 课堂「\(sess.title)」全覆盖转写成功落盘，已安全清理临时录音文件，释放存储。")
                }
            }
            saveSessions()
        }
    }

    /// 真正的 async/await 顺序补转写队列
    public func retryPendingChunks(for session: LessonSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let pendingTasks = sessions[idx].chunkTasks.filter { $0.status == .pending || $0.status == .failed }
        guard !pendingTasks.isEmpty else { return }
        
        sessions[idx].status = .pendingCatchUp
        saveSessions()
        
        Task {
            for task in pendingTasks.sorted(by: { $0.sequenceIndex < $1.sequenceIndex }) {
                // 真正的 async/await 顺序请求，等待网络与落盘完成后再进行下一个分片
                _ = await self.processChunkTask(sessionId: session.id, task: task)
            }
            // 队列全部处理完毕后，执行终结检查
            self.checkAndFinalizeSessionStorage(sessionId: session.id)
        }
    }

    /// 按顺序插入段落并按时间戳升序排序，杜绝网络并发乱序
    private func insertAndSortSegment(segment: TranscriptSegment, targetSessionId: UUID) {
        if let idx = self.sessions.firstIndex(where: { $0.id == targetSessionId }) {
            var segs = self.sessions[idx].segments
            // 幂等防重：检查是否已有相同 ID 或完全重叠相同起始时间与序号的段落
            if !segs.contains(where: { $0.id == segment.id || ($0.startTime == segment.startTime && $0.sequenceIndex == segment.sequenceIndex) }) {
                segs.append(segment)
                segs.sort {
                    if $0.startTime != $1.startTime {
                        return $0.startTime < $1.startTime
                    }
                    return $0.sequenceIndex < $1.sequenceIndex
                }
                self.sessions[idx].segments = segs
                if self.currentSession?.id == targetSessionId {
                    self.currentSession?.segments = segs
                }
                self.saveSessions()
            }
        }
    }
    
    public func pauseRecording() {
        guard isRecording && !isPaused else { return }
        engine.pause()
        isPaused = true
        currentSession?.status = .paused
        speechTask?.cancel()
        speechTask = nil
        capture?.attachSpeechRequest(nil)
        saveSessions()
    }
    
    public func resumeRecording() {
        guard isRecording && isPaused else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            isPaused = false
            currentSession?.status = .recording
            if currentSession?.mode == .realtime && transcriptionEngine == .apple {
                startSpeechRecognition()
            }
            saveSessions()
        } catch {
            errorMessage = "恢复录音失败：\(error.localizedDescription)"
        }
    }
    
    public func markMoment() {
        guard isRecording, var cur = currentSession else { return }
        let now = recordingElapsed
        cur.marks.append(now)
        
        for i in 0..<cur.segments.count {
            if now >= cur.segments[i].startTime && now <= cur.segments[i].endTime + 2 {
                cur.segments[i].isMarked = true
            }
        }
        
        self.currentSession = cur
        if let idx = sessions.firstIndex(where: { $0.id == cur.id }) {
            sessions[idx] = cur
            saveSessions()
        }
    }

    public func markMomentAt(_ timestamp: TimeInterval) {
        guard var cur = currentSession ?? sessions.first else { return }
        if !cur.marks.contains(timestamp) {
            cur.marks.append(timestamp)
        }
        for i in 0..<cur.segments.count {
            if timestamp >= cur.segments[i].startTime - 1 && timestamp <= cur.segments[i].endTime + 2 {
                cur.segments[i].isMarked = true
            }
        }
        if let idx = sessions.firstIndex(where: { $0.id == cur.id }) {
            sessions[idx] = cur
            saveSessions()
        }
        if currentSession?.id == cur.id {
            currentSession = cur
        }
    }
    
    public func toggleSegmentMark(session: LessonSession, segmentId: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        var sess = sessions[idx]
        if let segIdx = sess.segments.firstIndex(where: { $0.id == segmentId }) {
            sess.segments[segIdx].isMarked.toggle()
            let t = sess.segments[segIdx].startTime
            if sess.segments[segIdx].isMarked {
                if !sess.marks.contains(t) { sess.marks.append(t) }
            } else {
                sess.marks.removeAll { abs($0 - t) < 0.5 }
            }
            sessions[idx] = sess
            if currentSession?.id == sess.id {
                currentSession = sess
            }
            saveSessions()
        }
    }
    
    public func stopRecording() {
        guard isRecording, var cur = currentSession else { return }
        
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        
        speechTask?.cancel()
        speechTask = nil
        
        let remainingWav = (cur.mode == .realtime && transcriptionEngine == .stepfun && stepfunChunkInterval.rawValue > 0) ? capture?.takeCurrentSliceWavData(keepOverlapSeconds: 0) : nil
        let finalDuration = capture?.recordedDuration ?? recordingElapsed
        capture?.close()
        capture = nil
        
        cur.endedAt = Date()
        cur.duration = max(finalDuration, cur.duration)
        
        let rawURL = rawAudioURL(for: cur)
        let m4aURL = audioURL(for: cur)
        
        self.currentSession = nil
        self.isRecording = false
        self.isPaused = false
        self.recordingElapsed = 0
        
        // 1. 阶跃 ASR 实时切片模式：持久化最后残留的分片任务并触发转写
        if cur.mode == .realtime && transcriptionEngine == .stepfun && stepfunChunkInterval.rawValue > 0 && !stepfunApiKey.isEmpty {
            if let wav = remainingWav, wav.count > 44 + 8000 {
                self.currentChunkIndex += 1
                let chunkIdx = self.currentChunkIndex
                let chunkStart = self.lastChunkTime
                let chunkEnd = finalDuration
                let targetId = cur.id
                
                let chunkFileName = "chunk_\(chunkIdx).wav"
                let folder = self.chunksFolder(for: targetId)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let chunkPath = folder.appendingPathComponent(chunkFileName)
                    try wav.write(to: chunkPath, options: .atomic)
                    
                    let task = ChunkTranscriptionTask(
                        sequenceIndex: chunkIdx,
                        startTime: chunkStart,
                        endTime: chunkEnd,
                        chunkFileName: chunkFileName,
                        status: .pending
                    )
                    self.appendChunkTask(task, to: targetId)
                    Task {
                        await self.processChunkTask(sessionId: targetId, task: task)
                    }
                } catch {
                    self.errorMessage = "收尾音频切片写入失败：\(error.localizedDescription)"
                    print("[AudioWriteError] 末尾分片 \(chunkIdx) 写入沙盒失败: \(error)")
                }
            }
        }
        
        // 2. 模式与音频压缩处理
        if cur.mode == .recordOnly {
            cur.status = .recordOnlyCompleted
            if let idx = sessions.firstIndex(where: { $0.id == cur.id }) {
                sessions[idx] = cur
            }
            saveSessions()
            
            // 仅录音模式：真实调用 AudioCompressor 将 raw.caf 硬件压缩为正规 AAC 48kbps M4A
            let sessionToCompress = cur
            Task {
                if FileManager.default.fileExists(atPath: rawURL.path) {
                    do {
                        let compSize = try await AudioCompressor.compressToM4A(sourceURL: rawURL, destinationURL: m4aURL, bitrate: 48000)
                        await MainActor.run {
                            if let idx = self.sessions.firstIndex(where: { $0.id == sessionToCompress.id }) {
                                self.sessions[idx].audioSize = compSize
                                self.saveSessions()
                            }
                            try? FileManager.default.removeItem(at: rawURL)
                            print("[AudioCompressor] 仅录音模式完成正规 AAC 48kbps 压缩，真实文件大小: \(compSize) 字节")
                        }
                    } catch {
                        print("[AudioCompressor] 压缩失败，保留原始音频: \(error)")
                        try? FileManager.default.moveItem(at: rawURL, to: m4aURL)
                    }
                }
            }
        } else if cur.mode == .realtime {
            if let idx = sessions.firstIndex(where: { $0.id == cur.id }) {
                sessions[idx] = cur
            }
            saveSessions()
            
            // 实时模式：执行终结完整性核验
            self.checkAndFinalizeSessionStorage(sessionId: cur.id)
            
            // 容灾保护：若存在待补转写切片，在后台将 raw.caf 压缩为正规 AAC m4a 供后续播放与保存
            let sessionForSafety = cur
            Task {
                if FileManager.default.fileExists(atPath: rawURL.path) && !FileManager.default.fileExists(atPath: m4aURL.path) {
                    do {
                        let compSize = try await AudioCompressor.compressToM4A(sourceURL: rawURL, destinationURL: m4aURL, bitrate: 48000)
                        await MainActor.run {
                            if let idx = self.sessions.firstIndex(where: { $0.id == sessionForSafety.id }) {
                                self.sessions[idx].audioSize = compSize
                                self.saveSessions()
                            }
                            try? FileManager.default.removeItem(at: rawURL)
                        }
                    } catch {
                        try? FileManager.default.moveItem(at: rawURL, to: m4aURL)
                    }
                }
            }
        }
        
        // 3. 课后统一转写模式
        if cur.mode == .realtime && transcriptionEngine == .stepfun && stepfunChunkInterval == .fullLesson && !stepfunApiKey.isEmpty {
            let sessionToTranscribe = cur
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.transcribeOffline(for: sessionToTranscribe)
            }
        }
        
        // 4. Cloudflare R2 可选备份（非强制）：仅当用户显式选择云端模式时触发
        if R2UploadManager.shared.storageMode != .localOnly {
            let sessionToSync = cur
            Task {
                await self.triggerCloudSync(for: sessionToSync)
            }
        }
        
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 触发云端同步流程（严格校验通过后，仅在 cloudFirst 模式下释放本地副本）
    public func triggerCloudSync(for session: LessonSession) async {
        let localURL = audioURL(for: session)
        guard FileManager.default.fileExists(atPath: localURL.path) else { return }
        
        await R2UploadManager.shared.syncSessionToCloud(
            session: session,
            localFileURL: localURL
        ) { [weak self] newStatus, remoteKey in
            Task { @MainActor in
                guard let self = self else { return }
                if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                    self.sessions[idx].storageStatus = newStatus
                    if let key = remoteKey {
                        self.sessions[idx].remoteAudioKey = key
                    }
                    self.saveSessions()
                }
            }
        }
    }
    
    /// 手动重新上传或从失败中恢复
    public func retryUpload(session: LessonSession) {
        Task {
            await triggerCloudSync(for: session)
        }
    }

    public func switchTranscriptionEngine(_ engine: TranscriptionEngine, interval: StepfunChunkInterval? = nil) {
        self.transcriptionEngine = engine
        if let iv = interval {
            self.stepfunChunkInterval = iv
            UserDefaults.standard.set(iv.rawValue, forKey: "stepfunChunkInterval")
            UserDefaults.standard.set(true, forKey: "stepfunChunkInterval_set")
        }
        UserDefaults.standard.set(engine.rawValue, forKey: "transcriptionEngine")
        
        if isRecording && !isPaused && currentSession?.mode == .realtime {
            if engine == .apple {
                startSpeechRecognition()
            } else {
                speechTask?.cancel()
                speechTask = nil
                capture?.attachSpeechRequest(nil)
                self.lastChunkTime = self.recordingElapsed
            }
        }
    }

    // MARK: - 实时语音识别流 (苹果原生)
    
    private func startSpeechRecognition() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }
        
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        let epoch = UUID()
        self.speechEpoch = epoch
        self.speechStartedAt = Date()
        self.capture?.attachSpeechRequest(req)
        
        var lastText = ""
        var segmentStartTime = recordingElapsed
        
        speechTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.speechEpoch == epoch else { return }
                
                if let res = result {
                    let transcribed = res.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !transcribed.isEmpty && transcribed != lastText {
                        lastText = transcribed
                        let endTime = self.recordingElapsed
                        let isMarked = self.currentSession?.marks.contains { $0 >= segmentStartTime - 1 && $0 <= endTime + 1 } ?? false
                        
                        if var cur = self.currentSession {
                            if let last = cur.segments.last, abs(last.startTime - segmentStartTime) < 2 {
                                cur.segments[cur.segments.count - 1].text = transcribed
                                cur.segments[cur.segments.count - 1].endTime = endTime
                                cur.segments[cur.segments.count - 1].isMarked = isMarked || cur.segments[cur.segments.count - 1].isMarked
                            } else {
                                let newSeg = TranscriptSegment(sequenceIndex: cur.segments.count, startTime: segmentStartTime, endTime: endTime, text: transcribed, isMarked: isMarked)
                                cur.segments.append(newSeg)
                            }
                            self.currentSession = cur
                            if let idx = self.sessions.firstIndex(where: { $0.id == cur.id }) {
                                self.sessions[idx] = cur
                                self.saveSessions()
                            }
                        }
                    }
                    
                    if res.isFinal {
                        segmentStartTime = self.recordingElapsed
                        self.rotateSpeechTask()
                    }
                }
                
                if error != nil {
                    segmentStartTime = self.recordingElapsed
                    self.rotateSpeechTask()
                }
            }
        }
    }
    
    private func rotateSpeechTask() {
        guard isRecording && !isPaused else { return }
        speechTask?.cancel()
        speechTask = nil
        capture?.attachSpeechRequest(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.isRecording, !self.isPaused else { return }
            self.startSpeechRecognition()
        }
    }

    // MARK: - 课后离线/云端 ASR 转写
    
    public func transcribeOffline(for session: LessonSession) {
        guard !isTranscribingOffline else { return }
        let url = audioURL(for: session)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "录音文件在本地不存在（如已上传云端，请点击下载后再转写）"
            return
        }
        
        isTranscribingOffline = true
        
        Task {
            // 优先尝试 StepFun 阶跃云端转写
            if !stepfunApiKey.isEmpty {
                do {
                    let transcribedText = try await callStepFunASR(audioURL: url)
                    if !transcribedText.isEmpty {
                        var segs: [TranscriptSegment] = []
                        let lines = transcribedText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        let stepDur = session.duration / max(1.0, Double(lines.count))
                        for (idx, line) in lines.enumerated() {
                            let s = Double(idx) * stepDur
                            let e = s + stepDur
                            let isMarked = session.marks.contains { $0 >= s - 1 && $0 <= e + 1 }
                            segs.append(TranscriptSegment(sequenceIndex: idx, startTime: s, endTime: e, text: line, isMarked: isMarked))
                        }
                        if segs.isEmpty {
                            segs.append(TranscriptSegment(sequenceIndex: 0, startTime: 0, endTime: session.duration, text: transcribedText))
                        }
                        
                        if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                            self.sessions[idx].segments = segs
                            self.saveSessions()
                            // 保持音频文件完整保留！严禁删除本地音频！
                        }
                        self.isTranscribingOffline = false
                        return
                    }
                } catch {
                    print("StepFun ASR 失败，回退到 Apple 本地离线转写：", error)
                }
            }
            
            // 回退到 Apple 本地离线转写
            guard let recognizer = speechRecognizer, recognizer.isAvailable else {
                self.errorMessage = "系统语音识别暂不可用"
                self.isTranscribingOffline = false
                return
            }
            
            let req = SFSpeechURLRecognitionRequest(url: url)
            req.shouldReportPartialResults = false
            
            recognizer.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isTranscribingOffline = false
                    
                    if let res = result, res.isFinal {
                        let trans = res.bestTranscription
                        var newSegments: [TranscriptSegment] = []
                        for (i, seg) in trans.segments.enumerated() {
                            let isMarked = session.marks.contains { $0 >= seg.timestamp && $0 <= (seg.timestamp + seg.duration) }
                            newSegments.append(TranscriptSegment(
                                sequenceIndex: i,
                                startTime: seg.timestamp,
                                endTime: seg.timestamp + seg.duration,
                                text: seg.substring,
                                isMarked: isMarked
                            ))
                        }
                        if newSegments.isEmpty {
                            newSegments.append(TranscriptSegment(sequenceIndex: 0, startTime: 0, endTime: session.duration, text: trans.formattedString))
                        }
                        
                        if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                            self.sessions[idx].segments = newSegments
                            self.saveSessions()
                            // 保持音频文件完整保留！严禁删除本地音频！
                        }
                    } else if let err = error {
                        self.errorMessage = "离线识别失败：\(err.localizedDescription)"
                    }
                }
            }
        }
    }
    
    private func callStepFunASR(audioData: Data, prompt: String? = nil, filename: String = "audio.wav", mimeType: String = "audio/wav") async throws -> String {
        let cleanBase = stepfunBaseURL.hasSuffix("/") ? String(stepfunBaseURL.dropLast()) : stepfunBaseURL
        guard let url = URL(string: "\(cleanBase)/audio/transcriptions") else { throw URLError(.badURL) }
        
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(stepfunApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        
        var body = Data()
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(stepfunAsrModel)\r\n".data(using: .utf8)!)
        
        if let pr = prompt, !pr.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(pr)\r\n".data(using: .utf8)!)
        }
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if (200...299).contains(http.statusCode) {
                struct ASRResult: Codable {
                    let text: String?
                }
                let res = try JSONDecoder().decode(ASRResult.self, from: data)
                return res.text ?? ""
            } else {
                let errStr = String(data: data, encoding: .utf8) ?? "ASR HTTP Error"
                if http.statusCode == 400 && (errStr.contains("no speech") || errStr.contains("silence")) {
                    return ""
                }
                throw NSError(domain: "StepFunASR", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errStr])
            }
        }
        return ""
    }

    private func callStepFunASR(audioURL: URL) async throws -> String {
        let rawData = try Data(contentsOf: audioURL)
        let filename = audioURL.lastPathComponent.lowercased()
        let mime = filename.hasSuffix(".wav") ? "audio/wav" : (filename.hasSuffix(".mp3") ? "audio/mpeg" : (filename.hasSuffix(".m4a") ? "audio/m4a" : "audio/x-caf"))
        return try await callStepFunASR(audioData: rawData, prompt: nil, filename: audioURL.lastPathComponent, mimeType: mime)
    }

    // MARK: - 大模型 HTTP 调用 (DeepSeek 专属问答与智能笔记生成)
    
    public func callLLMApi(systemPrompt: String, userPrompt: String) async throws -> String {
        guard !llmApiKey.isEmpty else {
            throw NSError(domain: "LLMError", code: 401, userInfo: [NSLocalizedDescriptionKey: "尚未配置有效的 DeepSeek API Key"])
        }
        return try await executeChatCompletion(baseURL: llmBaseURL, model: llmModel, apiKey: llmApiKey, systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    private func executeChatCompletion(baseURL: String, model: String, apiKey: String, systemPrompt: String, userPrompt: String) async throws -> String {
        let cleanBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(cleanBase)/chat/completions") else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.3
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "LLMError", code: -1, userInfo: [NSLocalizedDescriptionKey: "网络无响应"])
        }
        
        guard (200...299).contains(http.statusCode) else {
            let errStr = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "LLMError", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errStr])
        }
        
        struct ChatChoice: Codable {
            struct Message: Codable {
                let content: String
            }
            let message: Message
        }
        struct ChatResponse: Codable {
            let choices: [ChatChoice]
        }
        
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let first = decoded.choices.first?.message.content else {
            throw NSError(domain: "LLMError", code: -1, userInfo: [NSLocalizedDescriptionKey: "AI 返回内容为空"])
        }
        return first
    }

    // MARK: - 智能笔记生成
    
    public func generateNotes(for session: LessonSession, style: NoteStyle) {
        isGeneratingNotes = true
        let fullText = session.fullTranscript
        
        Task {
            if !llmApiKey.isEmpty && !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let sysPrompt = """
                    你是一位西安建筑科技大学资深骨干名师。请根据以下课堂实录，撰写一份排版精美、结构清晰的【\(style.title)】笔记。
                    排版要求：
                    1. 必须使用标准 Markdown 格式：一级标题（#）、二级章节（##）、三级要点（###）。
                    2. 核心考点与公式对比必须制作成规整的 Markdown 表格（| 表头1 | 表头2 |，包含分割线 |---|---|）。
                    3. 老师着重强调的难点或作业要求请使用引用块（> 引用）显著标出。
                    4. 严格围绕课堂真实录音内容，条理分明，不要包含任何闲话或代码块外框包裹。
                    """
                    let markStr = session.marks.map { formatDuration($0) }.joined(separator: ", ")
                    let userPrompt = "【课程标题】\(session.title)\n【老师标记重点时间】\(markStr.isEmpty ? "无" : markStr)\n\n【课堂文字实录】\n\(fullText)"
                    
                    let aiResult = try await callLLMApi(systemPrompt: sysPrompt, userPrompt: userPrompt)
                    
                    if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                        var notes = self.sessions[idx].notes.filter { $0.style != style }
                        notes.append(LessonNote(style: style, content: aiResult))
                        self.sessions[idx].notes = notes
                        self.saveSessions()
                    }
                    self.isGeneratingNotes = false
                    return
                } catch {
                    print("AI 笔记生成失败，降级为本地规则整理：", error)
                }
            }
            
            // 本地兜底整理（明确标注为本地规则整理，不冒充 AI 大模型生成结果）
            let generated = Self.synthesizeNotes(fullText: fullText, marks: session.marks, style: style, courseTitle: session.title)
            if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                var notes = self.sessions[idx].notes.filter { $0.style != style }
                notes.append(LessonNote(style: style, content: generated))
                self.sessions[idx].notes = notes
                self.saveSessions()
            }
            self.isGeneratingNotes = false
        }
    }
    
    nonisolated private static func synthesizeNotes(fullText: String, marks: [TimeInterval], style: NoteStyle, courseTitle: String) -> String {
        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "当前课堂尚未完成语音转写，无法提炼课堂笔记。请等待实时转写完成或在课后点击「转写录音」。"
        }
        
        let lines = fullText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        switch style {
        case .detailedOutline:
            var out = "# \(courseTitle) · 详细纲要 (本地规则提炼)\n\n"
            out += "## 课堂实录知识主干\n"
            out += "- 依据本堂课录音整理出以下核心内容条目：\n\n"
            out += "## 课堂分段重点速览\n"
            out += "| 序号 | 录音摘录 | 说明 |\n"
            out += "|---|---|---|\n"
            for (idx, line) in lines.prefix(8).enumerated() {
                out += "| \(idx + 1) | \(line) | 课堂关键讲解点 |\n"
            }
            return out
            
        case .keyPoints:
            var out = "# \(courseTitle) · 核心要点清单 (本地规则提炼)\n\n"
            out += "## 重点语句速记\n"
            for (idx, line) in lines.prefix(6).enumerated() {
                out += "- **要点 \(idx + 1)**：\(line)\n"
            }
            return out
            
        case .examReview:
            var out = "# \(courseTitle) · 复习指南 (本地规则提炼)\n\n"
            out += "## 重点标记与复习回顾\n"
            for (idx, line) in lines.prefix(6).enumerated() {
                out += "\(idx + 1). \(line)\n"
            }
            return out
        }
    }

    // MARK: - 课程问答 (支持 90 分钟全堂课检索 + 单段长按选段提问)

    public func askQuestion(for session: LessonSession, query: String, segment: TranscriptSegment? = nil) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isAskingQA = true
        
        let citTime = segment?.startTime
        
        Task {
            if !llmApiKey.isEmpty {
                do {
                    let sysPrompt = """
                    你是西安建筑科技大学专属课程智能助教。请根据课堂录音实录回答学生的提问。
                    回答要求：
                    1. 逻辑严谨、条理清晰，使用精简规范的 Markdown 排版（必要时使用表格对比或列表）。
                    2. 若属于公式推导，请给出完整的计算逻辑步骤。
                    3. 必须在回答末尾或对应论述中标注引用的课堂实录时间范围（如 [12:35]）。
                    4. 如果课堂实录中确实没有提及该问题的内容，请如实说明“根据当前课堂录音实录，老师未提及该知识点或相关内容”，严禁编造不存在的授课内容或时间戳。
                    """
                    
                    var userPrompt = ""
                    if let seg = segment {
                        let contextSegments = self.findSurroundingSegments(in: session.segments, around: seg.startTime, windowSeconds: 120)
                        let contextText = contextSegments.map { "[\(formatDuration($0.startTime))] \($0.text)" }.joined(separator: "\n")
                        userPrompt = "【学生选中的课堂段落】[\(formatDuration(seg.startTime))]: \"\(seg.text)\"\n\n【选中段落上下文实录】\n\(contextText)\n\n【学生针对选段的提问】\n\(query)"
                    } else {
                        // 全堂课智能段落检索：扫描整节课（可覆盖 90 分钟完整录音），检索最相关的课堂片段
                        let relevantSegments = self.retrieveRelevantSegments(in: session.segments, query: query, maxTotalChars: 12000)
                        let lectureText = relevantSegments.map { "[\(formatDuration($0.startTime))] \($0.text)" }.joined(separator: "\n")
                        userPrompt = "【课程标题】\(session.title)\n【课堂录音检索相关实录（按时间顺序列出）】\n\(lectureText.isEmpty ? "（暂无实录文字）" : lectureText)\n\n【学生课堂提问】\n\(query)"
                    }
                    
                    let answer = try await callLLMApi(systemPrompt: sysPrompt, userPrompt: userPrompt)
                    
                    // 提取最佳引用时间戳
                    let bestTime = citTime ?? self.findBestCitationTime(in: session.segments, for: query)
                    
                    if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                        let qDisplay = segment != nil ? "[\(formatDuration(segment!.startTime))选段] \(query)" : query
                        let pair = QAPair(question: qDisplay, answer: answer, citationSeconds: bestTime)
                        self.sessions[idx].qaPairs.append(pair)
                        self.saveSessions()
                    }
                    self.isAskingQA = false
                    return
                } catch {
                    print("大模型问答失败，回退到本地检索：", error)
                }
            }
            
            // 本地兜底逻辑（未配置 API Key 或断网时）
            let bestCitation = citTime ?? self.findBestCitationTime(in: session.segments, for: query)
            let fallbackAnswer: String
            if session.segments.isEmpty {
                fallbackAnswer = "⚠️ 当前课堂录音尚未生成转写文字。若需使用课堂 AI 助教，请在课后点击「转写录音」或开启实时转写。"
            } else if llmApiKey.isEmpty {
                let matches = self.retrieveRelevantSegments(in: session.segments, query: query, maxTotalChars: 1500)
                if matches.isEmpty {
                    fallbackAnswer = "未在课堂实录中搜索到与「\(query)」直接相关的讲解片段。请在「设置」中填入大模型 API Key 以启用深度语义推理。"
                } else {
                    let quotes = matches.prefix(3).map { "> [\(formatDuration($0.startTime))] \($0.text)" }.joined(separator: "\n\n")
                    fallbackAnswer = "### 本地实录命中片段\n\n\(quotes)\n\n> 💡 提示：当前未配置 AI 大模型 Key，以上为本地关键词检索结果。配置 Key 后可获得系统化解答与公式推导。"
                }
            } else {
                fallbackAnswer = "⚠️ AI 助教服务连接超时，请检查网络连接后重试。"
            }
            
            if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                let pair = QAPair(question: query, answer: fallbackAnswer, citationSeconds: bestCitation)
                self.sessions[idx].qaPairs.append(pair)
                self.saveSessions()
            }
            self.isAskingQA = false
        }
    }
    
    /// 全堂课智能段落检索（支持 90 分钟完整课堂检索）
    public func retrieveRelevantSegments(in segments: [TranscriptSegment], query: String, maxTotalChars: Int = 12000) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }
        
        let totalChars = segments.reduce(0) { $0 + $1.text.count }
        if totalChars <= maxTotalChars {
            return segments.sorted { $0.startTime < $1.startTime }
        }
        
        let cleanQuery = query.lowercased()
        let queryTerms = cleanQuery.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        
        var scored: [(seg: TranscriptSegment, score: Double)] = []
        for seg in segments {
            var score: Double = 0
            let text = seg.text.lowercased()
            if text.contains(cleanQuery) { score += 10.0 }
            for term in queryTerms {
                if text.contains(term) { score += 3.0 }
            }
            if seg.isMarked { score += 2.0 }
            if score > 0 {
                scored.append((seg, score))
            }
        }
        
        let topSorted = scored.sorted { $0.score > $1.score }.prefix(15)
        var selectedIds = Set(topSorted.map { $0.seg.id })
        
        for (idx, seg) in segments.enumerated() {
            if selectedIds.contains(seg.id) {
                if idx > 0 { selectedIds.insert(segments[idx - 1].id) }
                if idx < segments.count - 1 { selectedIds.insert(segments[idx + 1].id) }
            }
        }
        
        let result = segments.filter { selectedIds.contains($0.id) }.sorted { $0.startTime < $1.startTime }
        return result.isEmpty ? Array(segments.prefix(12)) : result
    }
    
    private func findSurroundingSegments(in segments: [TranscriptSegment], around targetTime: TimeInterval, windowSeconds: TimeInterval) -> [TranscriptSegment] {
        let half = windowSeconds / 2.0
        return segments.filter { $0.startTime >= (targetTime - half) && $0.startTime <= (targetTime + half) }
            .sorted { $0.startTime < $1.startTime }
    }

    private func findBestCitationTime(in segments: [TranscriptSegment], for query: String) -> TimeInterval? {
        let clean = query.lowercased()
        for seg in segments {
            if seg.text.lowercased().contains(clean) {
                return seg.startTime
            }
        }
        let terms = clean.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
        for seg in segments {
            for term in terms {
                if seg.text.lowercased().contains(term) {
                    return seg.startTime
                }
            }
        }
        return nil
    }

    // MARK: - 音频回放与云端流式播放控制
    
    public func hasLocalAudio(for session: LessonSession) -> Bool {
        let m4a = audioURL(for: session)
        let raw = rawAudioURL(for: session)
        return FileManager.default.fileExists(atPath: m4a.path) || FileManager.default.fileExists(atPath: raw.path)
    }

    public func hasAudioFile(for session: LessonSession) -> Bool {
        return hasLocalAudio(for: session) || (session.remoteAudioKey != nil && !session.remoteAudioKey!.isEmpty)
    }

    public func playAudio(session: LessonSession, seekTo: TimeInterval? = nil) {
        let m4a = audioURL(for: session)
        let raw = rawAudioURL(for: session)
        let localURL = FileManager.default.fileExists(atPath: m4a.path) ? m4a : (FileManager.default.fileExists(atPath: raw.path) ? raw : nil)
        
        if let playURL = localURL {
            playLocalAudio(url: playURL, session: session, seekTo: seekTo)
        } else if let remoteKey = session.remoteAudioKey, let streamURL = R2UploadManager.shared.getPlaybackURL(for: remoteKey) {
            playCloudStreamAudio(url: streamURL, session: session, seekTo: seekTo)
        } else {
            errorMessage = "该课堂录音已被安全清理以释放手机存储，仅保留文字实录与 AI 纪要。"
        }
    }

    private func playLocalAudio(url: URL, session: LessonSession, seekTo: TimeInterval?) {
        do {
            if playingSessionId != session.id || audioPlayer == nil {
                streamingPlayer?.pause()
                streamingPlayer = nil
                
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
                try AVAudioSession.sharedInstance().setActive(true)
                let player = try AVAudioPlayer(contentsOf: url)
                player.enableRate = true
                player.rate = playbackRate
                player.prepareToPlay()
                self.audioPlayer = player
                self.playingSessionId = session.id
                self.playbackDuration = player.duration
            }
            
            if let target = seekTo, let player = audioPlayer {
                player.currentTime = min(target, player.duration)
            }
            
            audioPlayer?.play()
            isPlayingAudio = true
            
            playbackTimer?.invalidate()
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, let player = self.audioPlayer else { return }
                    self.playbackTime = player.currentTime
                    if !player.isPlaying {
                        self.isPlayingAudio = false
                        self.playbackTimer?.invalidate()
                    }
                }
            }
        } catch {
            errorMessage = "播放失败：\(error.localizedDescription)"
        }
    }
    
    private func playCloudStreamAudio(url: URL, session: LessonSession, seekTo: TimeInterval?) {
        do {
            audioPlayer?.stop()
            audioPlayer = nil
            playbackTimer?.invalidate()
            
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            
            if playingSessionId != session.id || streamingPlayer == nil {
                let playerItem = AVPlayerItem(url: url)
                let player = AVPlayer(playerItem: playerItem)
                self.streamingPlayer = player
                self.playingSessionId = session.id
                self.playbackDuration = session.duration
                
                let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                self.streamingTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.playbackTime = time.seconds
                    }
                }
            }
            
            if let target = seekTo, let player = streamingPlayer {
                let cmTarget = CMTime(seconds: min(target, session.duration), preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                player.seek(to: cmTarget)
            }
            
            streamingPlayer?.rate = playbackRate
            streamingPlayer?.play()
            isPlayingAudio = true
        } catch {
            errorMessage = "云端流式播放启动失败：\(error.localizedDescription)"
        }
    }
    
    public func pauseAudio() {
        audioPlayer?.pause()
        streamingPlayer?.pause()
        isPlayingAudio = false
        playbackTimer?.invalidate()
    }
    
    public func seekAudio(to time: TimeInterval) {
        if let player = audioPlayer {
            player.currentTime = min(time, playbackDuration)
        } else if let stream = streamingPlayer {
            let cmTime = CMTime(seconds: min(time, playbackDuration), preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            stream.seek(to: cmTime)
        }
        playbackTime = time
    }
    
    public func setPlaybackRate(_ rate: Float) {
        self.playbackRate = rate
        audioPlayer?.rate = rate
        if isPlayingAudio {
            streamingPlayer?.rate = rate
        }
    }

    // MARK: - 课程与课表操作
    
    public func importTimetable(data: Data) throws {
        let (parsedTimetable, parsedCourses) = try TimetableEngine.parsePDF(data: data)
        self.timetable = parsedTimetable
        saveTimetable()
        
        for pc in parsedCourses {
            if !courses.contains(where: { $0.name == pc.name }) {
                courses.append(pc)
            }
        }
        saveCourses()
        updateCourseSuggestion()
    }
    
    public func createCourse(name: String, teacher: String = "", room: String = "", colorHex: String = "#0A84FF") {
        let c = Course(name: name, teacher: teacher, room: room, colorHex: colorHex)
        courses.append(c)
        saveCourses()
        updateCourseSuggestion()
    }
    
    public func deleteCourse(course: Course) {
        courses.removeAll { $0.id == course.id }
        for i in 0..<sessions.count {
            if sessions[i].courseId == course.id {
                sessions[i].courseId = nil
            }
        }
        saveCourses()
        saveSessions()
        updateCourseSuggestion()
    }
    
    public func moveSession(_ session: LessonSession, to course: Course?) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].courseId = course?.id
            saveSessions()
        }
    }
    
    public func renameSession(_ session: LessonSession, newTitle: String) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            saveSessions()
        }
    }
    
    public func deleteSession(_ session: LessonSession, deleteCloudCopy: Bool = false) {
        if playingSessionId == session.id {
            pauseAudio()
            audioPlayer = nil
            streamingPlayer = nil
            playingSessionId = nil
        }
        try? FileManager.default.removeItem(at: audioURL(for: session))
        try? FileManager.default.removeItem(at: rawAudioURL(for: session))
        try? FileManager.default.removeItem(at: chunksFolder(for: session.id))
        
        if deleteCloudCopy, let remoteKey = session.remoteAudioKey {
            Task {
                let cleanBase = R2UploadManager.shared.workerBaseURL.hasSuffix("/") ? String(R2UploadManager.shared.workerBaseURL.dropLast()) : R2UploadManager.shared.workerBaseURL
                if let delURL = URL(string: "\(cleanBase)/api/classroom/recordings/\(remoteKey)") {
                    var req = URLRequest(url: delURL)
                    req.httpMethod = "DELETE"
                    if let token = KeychainHelper.get(key: "device_auth_token") {
                        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    _ = try? await URLSession.shared.data(for: req)
                }
            }
        }
        sessions.removeAll { $0.id == session.id }
        saveSessions()
    }

    private func formatDuration(_ sec: TimeInterval) -> String {
        let whole = Int(sec)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
