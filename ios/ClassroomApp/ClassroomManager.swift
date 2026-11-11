import AVFoundation
import Combine
import CoreMedia
import Foundation
import SwiftUI

private final class AudioCapture {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var totalFrames: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100
    private var writeFailed = false
    
    private var sliceBuffer = ClassroomSliceBuffer()
    private var sliceStepAccumulator: Double = 0
    private let voiceDetector: SileroVoiceDetector?

    private let collectSlices: Bool

    init(file: AVAudioFile, sampleRate: Double, collectSlices: Bool) {
        self.collectSlices = collectSlices
        self.voiceDetector = collectSlices ? SileroVoiceDetector() : nil
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
            
            // 重采样至 16kHz 单声道 PCM 供星辰 ASR 分段转写
            if collectSlices, let floatChannelData = buffer.floatChannelData {
                let channel0 = floatChannelData[0]
                let frameCount = Int(buffer.frameLength)
                
                var resampled: [Int16] = []
                resampled.reserveCapacity(Int(Double(frameCount) * 16000 / sampleRate) + 1)
                let step = sampleRate / 16000.0
                var idx: Double = sliceStepAccumulator
                while idx < Double(frameCount) {
                    let sampleIdx = Int(idx)
                    let rawFloat = channel0[sampleIdx]
                    let clamped = max(-1.0, min(1.0, rawFloat))
                    let int16Sample = Int16(clamped * 32767.0)
                    resampled.append(int16Sample)
                    idx += step
                }
                sliceStepAccumulator = idx - Double(frameCount)
                sliceBuffer.append(resampled) { [voiceDetector] window in
                    voiceDetector?.isSpeech(window)
                }
            }
            return nil
        } catch {
            writeFailed = true
            return error
        }
    }

    func takeSlice(final: Bool = false) -> (data: Data, start: Double, end: Double)? {
        lock.lock()
        defer { lock.unlock() }

        guard let slice = sliceBuffer.take(final: final) else { return nil }
        return (pcmToWav(samples: slice.samples, sampleRate: 16000),
                Double(slice.startSample) / 16000, Double(slice.endSample) / 16000)
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
        file = nil
        sliceBuffer = ClassroomSliceBuffer()
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
    @Published public private(set) var asrProvider: CloudTranscriptionProvider {
        didSet { UserDefaults.standard.set(asrProvider.rawValue, forKey: "cloudASRProvider") }
    }
    @Published public var stepFunApiKey: String {
        didSet { KeychainHelper.save(key: "stepFunCloudApiKey", value: stepFunApiKey) }
    }
    public var hasActiveASRKey: Bool { !activeASRKey.isEmpty }

    public func selectASRProvider(_ provider: CloudTranscriptionProvider) {
        guard !isRecording else { return }
        asrProvider = provider
    }


    private var activeASRKey: String {
        let key = asrProvider == .siliconFlow ? siliconFlowApiKey : stepFunApiKey
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    @Published public var siliconFlowApiKey: String {
        didSet { KeychainHelper.save(key: "siliconFlowApiKey", value: siliconFlowApiKey) }
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
    @Published public private(set) var answeringSessionID: UUID?
    @Published public private(set) var streamingAnswer = ""

    private let storageRoot: URL
    private let engine = AVAudioEngine()
    private var capture: AudioCapture?
    private var currentChunkIndex: Int = 0
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var streamingPlayer: AVPlayer?
    private var streamingTimeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var automaticMinutesQueue: [UUID] = []
    private var chunkQueue: [(sessionId: UUID, taskId: UUID)] = []
    private var chunkQueueWorker: Task<Void, Never>?
    @Published public private(set) var offlineTranscriptionSessionId: UUID?

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
        
        let previousHost = UserDefaults.standard.string(forKey: "stepfunBaseURL")
            .flatMap { URL(string: $0)?.host }
        let legacyKey = KeychainHelper.get(key: "stepfunApiKey")
            ?? UserDefaults.standard.string(forKey: "stepfunApiKey")
        let migratedSiliconFlow = previousHost == "api.siliconflow.cn" ? legacyKey : nil
        let migratedStepFun = previousHost == nil || previousHost == "api.stepfun.com" ? legacyKey : nil
        let bundledKeys = Self.importPersonalASRKeys()
        let siliconKey = KeychainHelper.get(key: "siliconFlowApiKey") ?? bundledKeys["siliconFlowApiKey"] ?? migratedSiliconFlow ?? ""
        let stepKey = KeychainHelper.get(key: "stepFunCloudApiKey") ?? bundledKeys["stepFunCloudApiKey"] ?? migratedStepFun ?? ""
        self.siliconFlowApiKey = siliconKey
        self.stepFunApiKey = stepKey
        self.asrProvider = UserDefaults.standard.string(forKey: "cloudASRProvider")
            .flatMap(CloudTranscriptionProvider.init(rawValue:))
            ?? (siliconKey.isEmpty && !stepKey.isEmpty ? .stepFun : .siliconFlow)
        if !siliconKey.isEmpty { KeychainHelper.save(key: "siliconFlowApiKey", value: siliconKey) }
        if !stepKey.isEmpty { KeychainHelper.save(key: "stepFunCloudApiKey", value: stepKey) }
        if previousHost == nil || previousHost == "api.stepfun.com" || previousHost == "api.siliconflow.cn" {
            UserDefaults.standard.removeObject(forKey: "stepfunApiKey")
        }

        try? FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        
        loadData()
        recoverInterruptedSessions()
        migrateLegacyRecordings()
        updateCourseSuggestion()
        setupInterruptionObserver()
        recoverMinutesJobs()
    }
    
    private static func importPersonalASRKeys() -> [String: String] {
        let marker = "personalASRKeysImported"
        guard !UserDefaults.standard.bool(forKey: marker),
              let url = Bundle.main.url(forResource: "PersonalASR", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let keys = try? PropertyListDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        var saved = true
        for account in ["siliconFlowApiKey", "stepFunCloudApiKey"] {
            guard let value = keys[account], !value.isEmpty else { continue }
            if KeychainHelper.get(key: account)?.isEmpty != false {
                saved = KeychainHelper.save(key: account, value: value) && saved
            }
        }
        if saved { UserDefaults.standard.set(true, forKey: marker) }
        return keys
    }

    public func resetAIDefaults() {
        self.llmBaseURL = "https://tokenrhythm.studio/v1"
        self.llmModel = "deepseek-v4.1-flash-1017"
        self.llmApiKey = ""
        self.siliconFlowApiKey = ""
        self.stepFunApiKey = ""
        KeychainHelper.delete(key: "llmApiKey")
        KeychainHelper.delete(key: "siliconFlowApiKey")
        KeychainHelper.delete(key: "stepFunCloudApiKey")
        KeychainHelper.delete(key: "stepfunApiKey")
        UserDefaults.standard.removeObject(forKey: "stepfunApiKey")
        UserDefaults.standard.removeObject(forKey: "stepfunBaseURL")
    }
    
    // MARK: - 持久化与文件管理
    
    private var coursesURL: URL { storageRoot.appendingPathComponent("courses.json") }
    private var courseTimetableURL: URL { storageRoot.appendingPathComponent("course-timetable.json") }
    private var deletedTimetableCourses: [Course] = []
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

    public func appendChunkTask(_ task: ChunkTranscriptionTask, to sessionId: UUID) throws {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { throw CocoaError(.fileNoSuchFile) }
        guard !sessions[idx].chunkTasks.contains(where: { $0.id == task.id || $0.sequenceIndex == task.sequenceIndex }) else { return }
        var updated = sessions
        updated[idx].chunkTasks.append(task)
        try JSONEncoder().encode(updated).write(to: sessionsURL, options: .atomic)
        sessions = updated
        if currentSession?.id == sessionId { currentSession?.chunkTasks = updated[idx].chunkTasks }
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
        
        if let data = try? Data(contentsOf: courseTimetableURL),
           let state = try? decoder.decode(CourseTimetableState.self, from: data) {
            courses = state.current.courses
            timetable = state.current.timetable
            lastCommittedCourses = state.previousImport?.courses
            lastCommittedTimetable = state.previousImport?.timetable
            lastCommittedDeletedCourses = state.previousImport?.deletedCourses
            deletedTimetableCourses = state.deletedCourses
        } else {
            if let data = try? Data(contentsOf: timetableURL), let loaded = try? decoder.decode(TimetableData.self, from: data) {
                timetable = loaded
            } else { timetable = TimetableData() }
            if let data = try? Data(contentsOf: coursesURL), let loaded = try? decoder.decode([Course].self, from: data) {
                courses = loaded
            } else { courses = TimetableEngine.coursesFrom(slots: timetable.slots) }
        }

        if let data = try? Data(contentsOf: sessionsURL), let loaded = try? decoder.decode([LessonSession].self, from: data) {
            self.sessions = loaded.sorted { $0.startedAt > $1.startedAt }
            let deletedIds = Set(deletedTimetableCourses.map(\.id))
            var repaired = false
            for index in sessions.indices {
                if let courseId = sessions[index].courseId, deletedIds.contains(courseId) {
                    sessions[index].courseId = nil
                    repaired = true
                }
            }
            if repaired { saveSessions() }
        }
    }

    private func makeCourseTimetableState(courses: [Course], timetable: TimetableData,
                                          previous: CourseTimetableSnapshot? = nil) -> CourseTimetableState {
        let undo: CourseTimetableSnapshot?
        if let previous { undo = previous }
        else if let oldCourses = lastCommittedCourses, let oldTable = lastCommittedTimetable {
            undo = CourseTimetableSnapshot(courses: oldCourses, timetable: oldTable, deletedCourses: lastCommittedDeletedCourses)
        } else { undo = nil }
        return CourseTimetableState(current: CourseTimetableSnapshot(courses: courses, timetable: timetable),
            previousImport: undo, deletedCourses: deletedTimetableCourses)
    }

    public func saveCourses() {
        do { try makeCourseTimetableState(courses: courses, timetable: timetable).write(to: courseTimetableURL) }
        catch { errorMessage = "课程与课表保存失败：\(error.localizedDescription)" }
    }

    public func saveTimetable() { saveCourses() }

    public func attachmentURL(_ attachment: LessonAttachment) -> URL {
        storageRoot.appendingPathComponent("attachments").appendingPathComponent(attachment.fileName)
    }

    public func addAttachment(sessionId: UUID, time: TimeInterval, segmentId: UUID?, jpeg: Data) throws {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { throw CocoaError(.fileNoSuchFile) }
        guard !jpeg.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let attachment = LessonAttachment(time: max(0, time), segmentId: segmentId, fileName: UUID().uuidString + ".jpg")
        let url = attachmentURL(attachment)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
        var updated = sessions
        updated[index].attachments.append(attachment)
        do {
            try JSONEncoder().encode(updated).write(to: sessionsURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        sessions = updated
        if currentSession?.id == sessionId { currentSession?.attachments = updated[index].attachments }
    }

    public func removeAttachment(sessionId: UUID, attachment: LessonAttachment) throws {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        var updated = sessions
        updated[index].attachments.removeAll { $0.id == attachment.id }
        try JSONEncoder().encode(updated).write(to: sessionsURL, options: .atomic)
        sessions = updated
        if currentSession?.id == sessionId { currentSession?.attachments = updated[index].attachments }
        let url = attachmentURL(attachment)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
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
                // The main recording remains available for playback, photos and export after restart.
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
        
        guard mode != .realtime || hasActiveASRKey else {
            errorMessage = "请先填写「\(asrProvider.title)」的 API Key"
            return
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
            mode: mode,
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
            
            let sink = AudioCapture(file: file, sampleRate: format.sampleRate, collectSlices: mode == .realtime)
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
            // 录音计时与停顿分段
            recordingTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, self.isRecording, !self.isPaused else { return }
                    if let cap = self.capture {
                        self.recordingElapsed = cap.recordedDuration
                        self.currentSession?.duration = self.recordingElapsed
                    }
                    
                    if self.currentSession?.mode == .realtime,
                       let slice = self.capture?.takeSlice(),
                       let sessionId = self.currentSession?.id {
                        self.enqueueSlice(slice, sessionId: sessionId)
                    }
                }
            }
            if let recordingTimer { RunLoop.main.add(recordingTimer, forMode: .common) }
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
        guard currentTask.status != .transcribing else { return false }
        
        self.updateChunkTask(sessionId: sessionId, taskId: task.id) {
            $0.status = .transcribing
            $0.lastError = nil
        }
        self.isChunkTranscribing = true
        
        let chunkURL = self.chunkFileURL(sessionId: sessionId, fileName: task.chunkFileName)
        guard FileManager.default.fileExists(atPath: chunkURL.path),
              let audioData = try? Data(contentsOf: chunkURL),
              audioData.count > 44 else {
            self.updateChunkTask(sessionId: sessionId, taskId: task.id) {
                $0.status = .failed
                $0.lastError = "分片音频数据文件不存在或损坏"
            }
            self.isChunkTranscribing = false
            return false
        }
        
        do {
            let transcribed = try await self.callCloudASR(audioData: audioData)
            guard try self.completeChunkTask(sessionId: sessionId, taskId: task.id, text: transcribed) else {
                self.isChunkTranscribing = false
                return false
            }
            self.isChunkTranscribing = false

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

    /// 根据持久化分段任务更新课堂状态，完整录音可供回听和补转写。
    public func checkAndFinalizeSessionStorage(sessionId: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let sess = sessions[idx]
        
        // 1. 录音或暂停中不执行终结清理
        if sess.status == .recording || sess.status == .paused { return }
        
        // 2. 仅录音模式绝不自动清理任何录音！
        if sess.mode == .recordOnly && sess.chunkTasks.isEmpty {
            sessions[idx].status = .recordOnlyCompleted
            saveSessions()
            return
        }
        
        guard !sess.chunkTasks.isEmpty else {
            sessions[idx].status = .pendingCatchUp
            saveSessions()
            return
        }
        if sess.chunkTasks.contains(where: { $0.status == .pending || $0.status == .transcribing }) {
            sessions[idx].status = .pendingCatchUp
        } else if sess.chunkTasks.contains(where: { $0.status == .failed }) {
            sessions[idx].status = .transcriptionFailed
        } else {
            sessions[idx].status = .completed
        }
        saveSessions()
        if !sessions[idx].chunkTasks.contains(where: { $0.status == .pending || $0.status == .transcribing }) {
            finishOfflineTranscription(sessionId: sessionId)
        }
        if sessions[idx].status == .completed { enqueueAutomaticMinutes(sessionId: sessionId) }
    }

    /// 真正的 async/await 顺序补转写队列
    public func retryPendingChunks(for session: LessonSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let pendingTasks = sessions[idx].chunkTasks.filter { $0.status == .pending || $0.status == .failed }
        guard !pendingTasks.isEmpty else { return }
        
        sessions[idx].status = .pendingCatchUp
        saveSessions()
        
        for task in pendingTasks.sorted(by: { $0.sequenceIndex < $1.sequenceIndex }) {
            queueChunkTask(sessionId: session.id, taskId: task.id)
        }
    }

    private func queueChunkTask(sessionId: UUID, taskId: UUID) {
        guard !chunkQueue.contains(where: { $0.taskId == taskId }) else { return }
        chunkQueue.append((sessionId, taskId))
        guard chunkQueueWorker == nil else { return }
        chunkQueueWorker = Task { [weak self] in
            guard let self else { return }
            while !self.chunkQueue.isEmpty {
                let liveIndex = self.chunkQueue.firstIndex { item in
                    self.currentSession?.id == item.sessionId && self.currentSession?.mode == .realtime
                } ?? 0
                let next = self.chunkQueue.remove(at: liveIndex)
                guard let session = self.sessions.first(where: { $0.id == next.sessionId }),
                      let task = session.chunkTasks.first(where: { $0.id == next.taskId }),
                      task.status == .pending || task.status == .failed else { continue }
                _ = await self.processChunkTask(sessionId: next.sessionId, task: task)
                self.checkAndFinalizeSessionStorage(sessionId: next.sessionId)
            }
            self.chunkQueueWorker = nil
        }
    }

    private func completeChunkTask(sessionId: UUID, taskId: UUID, text: String) throws -> Bool {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }),
              let taskIndex = sessions[sessionIndex].chunkTasks.firstIndex(where: { $0.id == taskId }) else {
            return false
        }

        var session = sessions[sessionIndex]
        session.completeTranscriptChunk(at: taskIndex, text: text)
        var updatedSessions = sessions
        updatedSessions[sessionIndex] = session
        try JSONEncoder().encode(updatedSessions).write(to: sessionsURL, options: .atomic)
        sessions = updatedSessions
        if currentSession?.id == sessionId {
            currentSession?.chunkTasks = session.chunkTasks
            currentSession?.segments = session.segments
        }
        return true
    }

    public var currentRecordingTime: TimeInterval { capture?.recordedDuration ?? recordingElapsed }

    public func pauseRecording() {
        guard isRecording && !isPaused else { return }
        engine.pause()
        if let sessionId = currentSession?.id {
            while let slice = capture?.takeSlice(final: true) { enqueueSlice(slice, sessionId: sessionId) }
        }
        recordingElapsed = currentRecordingTime
        isPaused = true
        currentSession?.status = .paused
        if let id = currentSession?.id, let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].status = .paused
            sessions[index].duration = recordingElapsed
        }
        saveSessions()
    }
    
    public func resumeRecording() {
        guard isRecording && isPaused else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            isPaused = false
            currentSession?.status = .recording
            if let id = currentSession?.id, let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index].status = .recording
            }
            saveSessions()
        } catch {
            errorMessage = "恢复录音失败：\(error.localizedDescription)"
        }
    }
    
    public func markMoment() {
        guard isRecording, var cur = currentSession else { return }
        let now = currentRecordingTime
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
    
    public func stopRecording(discard: Bool = false) {
        guard isRecording, var cur = currentSession else { return }
        
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        
        if !discard {
            while let slice = capture?.takeSlice(final: true) { enqueueSlice(slice, sessionId: cur.id) }
            cur.chunkTasks = sessions.first(where: { $0.id == cur.id })?.chunkTasks ?? cur.chunkTasks
        }
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
        
        if discard {
            deleteSession(cur)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return
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
            cur.status = .pendingCatchUp
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

    private func enqueueSlice(_ slice: (data: Data, start: Double, end: Double), sessionId: UUID) {
        currentChunkIndex += 1
        let index = currentChunkIndex
        let filename = "chunk_\(index).wav"
        let folder = chunksFolder(for: sessionId)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try slice.data.write(to: folder.appendingPathComponent(filename), options: .atomic)
            let task = ChunkTranscriptionTask(
                sequenceIndex: index, startTime: slice.start, endTime: slice.end,
                chunkFileName: filename, status: .pending
            )
            try appendChunkTask(task, to: sessionId)
            queueChunkTask(sessionId: sessionId, taskId: task.id)
        } catch {
            errorMessage = "音频分段保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 课后离线/云端 ASR 转写
    
    private func finishOfflineTranscription(sessionId: UUID) {
        if offlineTranscriptionSessionId == sessionId {
            offlineTranscriptionSessionId = nil
            isTranscribingOffline = false
        }
    }

    public func transcribeOffline(for session: LessonSession) {
        guard !isTranscribingOffline,
              let current = sessions.first(where: { $0.id == session.id }),
              currentSession?.id != session.id || !isRecording else { return }
        if current.chunkTasks.contains(where: { $0.status == .transcribing }) { return }
        if current.chunkTasks.contains(where: { $0.status == .pending || $0.status == .failed }) {
            retryPendingChunks(for: current)
            return
        }
        guard current.segments.isEmpty else {
            errorMessage = "这节课已有实录，保留现有内容；失败分段可单独重试"
            return
        }
        guard hasActiveASRKey else {
            errorMessage = "请先填写首页所选转写服务的 API Key"
            return
        }
        let compressed = audioURL(for: current)
        let raw = rawAudioURL(for: current)
        let url = FileManager.default.fileExists(atPath: compressed.path) ? compressed : raw
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "本地录音不存在，如已备份到云端请先下载音频"
            return
        }
        let folder = chunksFolder(for: session.id)
        let modelURL = Bundle.main.url(forResource: "silero_vad.int8", withExtension: "onnx")
        errorMessage = ""
        isTranscribingOffline = true
        offlineTranscriptionSessionId = session.id
        Task {
            var prepared: [ChunkTranscriptionTask] = []
            do {
                prepared = try await Task.detached(priority: .utility) {
                    try OfflineAudioSegmenter.prepare(audioURL: url, sessionChunkDirectory: folder, modelURL: modelURL)
                }.value
                guard let index = self.sessions.firstIndex(where: { $0.id == session.id }) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                var updated = self.sessions
                updated[index].chunkTasks = prepared
                updated[index].status = .pendingCatchUp
                try JSONEncoder().encode(updated).write(to: self.sessionsURL, options: .atomic)
                self.sessions = updated
                for task in prepared { self.queueChunkTask(sessionId: session.id, taskId: task.id) }
            } catch {
                // Only remove this unpublished attempt, never the source recording or existing tasks.
                if let first = prepared.first {
                    let attemptDirectory = folder.appendingPathComponent(first.chunkFileName).deletingLastPathComponent()
                    try? FileManager.default.removeItem(at: attemptDirectory)
                }
                self.finishOfflineTranscription(sessionId: session.id)
                self.errorMessage = "课后转写准备失败，原录音已保留：\(error.localizedDescription)"
            }
        }
    }

    private func callCloudASR(audioData: Data, filename: String = "audio.wav", mimeType: String = "audio/wav") async throws -> String {
        let provider = asrProvider
        let key = activeASRKey
        guard !key.isEmpty else {
            throw NSError(domain: "CloudASR", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "请先填写当前转写引擎的 API Key"])
        }
        let request = try ClassroomASRRequest.make(provider: provider, key: key,
            audioData: audioData, filename: filename, mimeType: mimeType)

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
                throw NSError(domain: "CloudASR", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errStr])
            }
        }
        return ""
    }

    private func callCloudASR(audioURL: URL) async throws -> String {
        let rawData = try Data(contentsOf: audioURL)
        let filename = audioURL.lastPathComponent.lowercased()
        let mime = filename.hasSuffix(".wav") ? "audio/wav" : (filename.hasSuffix(".mp3") ? "audio/mpeg" : (filename.hasSuffix(".m4a") ? "audio/m4a" : "audio/x-caf"))
        return try await callCloudASR(audioData: rawData, filename: audioURL.lastPathComponent, mimeType: mime)
    }

    // MARK: - 大模型 HTTP 调用 (DeepSeek 专属问答与智能笔记生成)
    
    public func callLLMApi(systemPrompt: String, userPrompt: String, imageJPEG: Data? = nil, onUpdate: ((String) -> Void)? = nil) async throws -> String {
        guard !llmApiKey.isEmpty else {
            throw NSError(domain: "LLMError", code: 401, userInfo: [NSLocalizedDescriptionKey: "尚未配置有效的 DeepSeek API Key"])
        }
        return try await executeChatCompletion(baseURL: llmBaseURL, model: llmModel, apiKey: llmApiKey, systemPrompt: systemPrompt, userPrompt: userPrompt, imageJPEG: imageJPEG, onUpdate: onUpdate)
    }

    private func executeChatCompletion(baseURL: String, model: String, apiKey: String, systemPrompt: String, userPrompt: String, imageJPEG: Data? = nil, onUpdate: ((String) -> Void)? = nil) async throws -> String {
        let cleanBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(cleanBase)/chat/completions") else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        
        let userContent: Any
        if let imageJPEG {
            userContent = [
                ["type": "text", "text": userPrompt],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + imageJPEG.base64EncodedString()]]
            ] as [[String: Any]]
        } else {
            userContent = userPrompt
        }
        let mathFormat = "请用标准 Markdown 排版。行内公式用单美元符号包裹，独立公式用双美元符号包裹。避免用裸花括号或代码块包裹公式。"
        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt + "\n" + mathFormat],
                ["role": "user", "content": userContent]
            ],
            "temperature": 0.3
        ]
        if onUpdate != nil {
            payload["stream"] = true
            request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let data: Data
        let response: URLResponse
        if let onUpdate {
            let (bytes, streamResponse) = try await URLSession.shared.bytes(for: request)
            response = streamResponse
            if let http = streamResponse as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               http.mimeType?.lowercased() == "text/event-stream" {
                return try await readAnswerStream(bytes, onUpdate: onUpdate)
            }
            var body = Data()
            for try await byte in bytes {
                guard body.count < 2_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
                body.append(byte)
            }
            data = body
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }
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

    private func readAnswerStream(_ bytes: URLSession.AsyncBytes, onUpdate: (String) -> Void) async throws -> String {
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
                let finish_reason: String?
            }
            let choices: [Choice]?
            let error: ServiceError?
            struct ServiceError: Decodable { let message: String? }
        }

        var answer = ""
        var lastUpdate = Date.distantPast
        var finishReason: String?
        var ended = false
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" {
                    ended = true
                    break
                }
                guard !payload.isEmpty else { continue }
                let chunk = try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8))
                if chunk.error != nil { throw URLError(.badServerResponse) }
                guard let choice = chunk.choices?.first else { continue }
                finishReason = choice.finish_reason ?? finishReason
                if let part = choice.delta?.content, !part.isEmpty {
                    answer += part
                    let now = Date()
                    if now.timeIntervalSince(lastUpdate) >= 0.2 {
                        onUpdate(answer)
                        lastUpdate = now
                    }
                }
            }
        } catch {
            guard !answer.isEmpty else { throw error }
            return answer + "\n\n> 连接中断，以上为已收到的内容。"
        }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }
        if finishReason == "length" { return answer + "\n\n> 回答达到长度上限，可继续追问。" }
        if !ended && finishReason == nil { return answer + "\n\n> 连接中断，以上为已收到的内容。" }
        return answer
    }

    // MARK: - 智能笔记生成
    
    private func recoverMinutesJobs() {
        var updated = false
        for index in sessions.indices {
            if sessions[index].recoverInterruptedMinutes() { updated = true }
        }
        if updated { saveSessions() }
        let pending = sessions.filter { $0.minutesGenerationState == .queued }.map(\.id)
        Task { for id in pending { self.enqueueAutomaticMinutes(sessionId: id) } }
    }

    private func enqueueAutomaticMinutes(sessionId: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionId }),
              session.status != .recording, session.status != .paused,
              !session.segments.isEmpty,
              session.chunkTasks.allSatisfy({ $0.status == .completed }),
              !session.automaticMinutesAttempted,
              !session.notes.contains(where: { $0.style == .minutes }) else { return }
        if !automaticMinutesQueue.contains(sessionId) {
            guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
            var updated = sessions
            updated[index].minutesGenerationState = .queued
            do {
                try JSONEncoder().encode(updated).write(to: sessionsURL, options: .atomic)
                sessions = updated
                automaticMinutesQueue.append(sessionId)
            } catch {
                errorMessage = "纪要任务保存失败：\(error.localizedDescription)"
                return
            }
        }
        drainAutomaticMinutesQueue()
    }

    private func drainAutomaticMinutesQueue() {
        guard !isGeneratingNotes, !automaticMinutesQueue.isEmpty else { return }
        let id = automaticMinutesQueue.removeFirst()
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].automaticMinutesAttempted,
              !sessions[index].notes.contains(where: { $0.style == .minutes }) else {
            drainAutomaticMinutesQueue()
            return
        }
        var updated = sessions
        updated[index].automaticMinutesAttempted = true
        do {
            try JSONEncoder().encode(updated).write(to: sessionsURL, options: .atomic)
            sessions = updated
            generateNotes(for: sessions[index], style: .minutes)
        } catch { errorMessage = "无法保存纪要任务：\(error.localizedDescription)" }
        if !isGeneratingNotes { drainAutomaticMinutesQueue() }
    }

    public func saveNoteContent(sessionId: UUID, style: NoteStyle, content: String, generated: Bool = false) throws {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var updated = sessions
        if let noteIndex = updated[index].notes.firstIndex(where: { $0.style == style }) {
            updated[index].notes[noteIndex].content = content
        } else {
            updated[index].notes.append(LessonNote(style: style, content: content))
        }
        if style == .minutes {
            updated[index].minutesGenerationError = nil
            updated[index].minutesGenerationState = generated ? .completed : .edited
        }
        try JSONEncoder().encode(updated).write(to: sessionsURL, options: .atomic)
        sessions = updated
    }

    public func generateNotes(for session: LessonSession, style: NoteStyle) {
        guard !isGeneratingNotes else { return }
        let session = sessions.first(where: { $0.id == session.id }) ?? session
        let fullText = session.fullTranscript
        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "课堂还没有转写文字，暂时无法生成纪要"
            return
        }
        errorMessage = ""
        if style == .minutes, let index = sessions.firstIndex(where: { $0.id == session.id }) {
            var updated = sessions
            updated[index].minutesGenerationState = .generating
            updated[index].minutesGenerationError = nil
            do {
                try JSONEncoder().encode(updated).write(to: sessionsURL, options: .atomic)
                sessions = updated
            } catch {
                errorMessage = "纪要任务保存失败：\(error.localizedDescription)"
                return
            }
        }
        isGeneratingNotes = true
        let originalContent = session.notes.first(where: { $0.style == style })?.content
        Task {
            defer {
                self.isGeneratingNotes = false
                self.drainAutomaticMinutesQueue()
            }
            do {
                let result: String
                if !llmApiKey.isEmpty {
                    let system = """
                    仅根据课堂实录整理中文 Markdown 笔记，不编造信息。
                    保留原始 [分:秒] 时间引用，重要结论和作业须能回听核对。
                    未明确提到的作业、日期、负责人和要求写「未提及」。
                    """
                    let format = style == .minutes
                        ? "按「课堂内容」「重点」「作业与提醒」三个二级标题整理纪要。"
                        : "整理为「\(style.title)」，公式可使用 Markdown，注意保留老师原话含义。"
                    var source = session.segments.sorted { $0.startTime < $1.startTime }
                        .map { "[\(formatDuration($0.startTime))] \($0.text)" }.joined(separator: "\n")
                    // Bound every request, including a single unusually long ASR paragraph.
                    while source.count > 12000 {
                        let batches = ClassroomTextBatches.split(source, limit: 8000)
                        var summaries: [String] = []
                        for batch in batches {
                            let partial = try await callLLMApi(systemPrompt: system,
                                userPrompt: "压缩以下课堂片段至不超过 1200 字，保留概念、结论、明确作业及其原始时间引用，不推测遗漏内容。\n\n" + batch)
                            guard !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                throw URLError(.cannotDecodeContentData)
                            }
                            summaries.append(partial)
                        }
                        let reduced = summaries.joined(separator: "\n\n")
                        guard reduced.count < source.count else {
                            throw NSError(domain: "ClassroomMinutes", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "分段纪要未能缩短，请重试或调整模型"])
                        }
                        source = reduced
                    }
                    result = try await callLLMApi(systemPrompt: system + "\n" + format,
                        userPrompt: "课程：\(session.title)\n\n" + source)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else if style == .minutes {
                    throw NSError(domain: "ClassroomMinutes", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "请先配置 AI 模型和 API Key，再重试纪要"])
                } else {
                    result = Self.synthesizeNotes(fullText: fullText, marks: session.marks, style: style, courseTitle: session.title)
                }
                guard !result.isEmpty else { throw URLError(.cannotDecodeContentData) }
                guard let latest = sessions.first(where: { $0.id == session.id }) else { return }
                guard latest.notes.first(where: { $0.style == style })?.content == originalContent else {
                    errorMessage = "笔记已在生成期间被编辑，已保留你的修改"
                    return
                }
                try saveNoteContent(sessionId: session.id, style: style, content: result, generated: true)
            } catch {
                errorMessage = "\(style.title)生成失败：\(error.localizedDescription)"
                if style == .minutes, let index = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions[index].minutesGenerationError = errorMessage
                    sessions[index].minutesGenerationState = .failed
                    saveSessions()
                }
            }
        }
    }

    nonisolated private static func synthesizeNotes(fullText: String, marks: [TimeInterval], style: NoteStyle, courseTitle: String) -> String {
        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "当前课堂尚未完成语音转写，无法提炼课堂笔记。请等待实时转写完成或在课后点击「转写录音」。"
        }
        
        let lines = fullText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        switch style {
        case .minutes:
            return ""
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

    public func recentQuestionSegments(for session: LessonSession) -> [TranscriptSegment] {
        let end = currentSession?.id == session.id && isRecording
            ? currentRecordingTime : max(session.duration, session.segments.map(\.endTime).max() ?? 0)
        return ClassroomQuestionContext.recent(session.segments, end: end)
    }

    public func askQuestion(for session: LessonSession, query: String, segment: TranscriptSegment? = nil, imageJPEG: Data? = nil, recentOnly: Bool = false) {
        guard !isAskingQA, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let segments = recentOnly ? recentQuestionSegments(for: session) : session.segments
        if recentOnly && segments.isEmpty && imageJPEG == nil {
            errorMessage = "最近 3 分钟还没有可用转写"
            return
        }
        streamingAnswer = ""
        answeringSessionID = session.id
        isAskingQA = true
        
        let citTime = segment?.startTime
        let imageLabel = imageJPEG == nil ? "" : "（附图）"
        let questionLabel = query + imageLabel
        
        Task {
            defer {
                self.streamingAnswer = ""
                self.answeringSessionID = nil
                self.isAskingQA = false
            }
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
                    } else if recentOnly {
                        let recentText = segments.map { "[\(formatDuration($0.startTime))] \($0.text)" }.joined(separator: "\n")
                        userPrompt = "【最近 3 分钟已完成的课堂实录】\n\(recentText)\n\n【提问】\(query)\n先给一句简短答案。"
                    } else {
                        // 全堂课智能段落检索：扫描整节课（可覆盖 90 分钟完整录音），检索最相关的课堂片段
                        let relevantSegments = self.retrieveRelevantSegments(in: session.segments, query: query, maxTotalChars: 12000)
                        let lectureText = relevantSegments.map { "[\(formatDuration($0.startTime))] \($0.text)" }.joined(separator: "\n")
                        userPrompt = "【课程标题】\(session.title)\n【课堂录音检索相关实录（按时间顺序列出）】\n\(lectureText.isEmpty ? "（暂无实录文字）" : lectureText)\n\n【学生课堂提问】\n\(query)"
                    }
                    
                    if imageJPEG != nil {
                        userPrompt += "\n请分析随题图片，明确区分图片里的内容与课堂实录。即使暂无实录，也可以解释图片本身。"
                    }
                    let recent = session.qaPairs.suffix(3).map { pair in
                        "问：\(pair.question)\n答：\(pair.answer.prefix(1200))"
                    }.joined(separator: "\n\n")
                    if !recentOnly && !recent.isEmpty {
                        userPrompt = "【最近问答，供理解追问】\n\(recent)\n\n" + userPrompt
                    }
                    let answer = try await callLLMApi(systemPrompt: sysPrompt, userPrompt: userPrompt, imageJPEG: imageJPEG) { partial in
                        self.streamingAnswer = partial
                    }
                    
                    // 提取最佳引用时间戳
                    let bestTime = citTime ?? self.findBestCitationTime(in: segments, for: query)
                    
                    if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                        let qDisplay = segment != nil ? "[\(formatDuration(segment!.startTime))选段] \(questionLabel)" : questionLabel
                        var pair = QAPair(question: qDisplay, answer: answer, citationSeconds: bestTime, imageJPEG: imageJPEG)
                        pair.scope = segment != nil ? "segment" : (recentOnly ? "recent" : "whole")
                pair.originalQuery = query
                self.sessions[idx].qaPairs.append(pair)
                        self.saveSessions()
                    }
                    return
                } catch {
                    print("大模型问答失败，回退到本地检索：", error)
                }
            }
            
            // 本地兜底逻辑（未配置 API Key 或断网时）
            let bestCitation = citTime ?? self.findBestCitationTime(in: segments, for: query)
            let fallbackAnswer: String
            if imageJPEG != nil {
                fallbackAnswer = llmApiKey.isEmpty ? "请先在设置中配置支持图片的 AI 模型和 API Key。" : "图片问答请求失败。请检查网络，确认当前模型支持图片后重新发送。"
            } else if session.segments.isEmpty {
                fallbackAnswer = "⚠️ 当前课堂录音尚未生成转写文字。若需使用课堂 AI 助教，请在课后点击「转写录音」或开启实时转写。"
            } else if llmApiKey.isEmpty {
                let matches = self.retrieveRelevantSegments(in: segments, query: query, maxTotalChars: 1500)
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
                var pair = QAPair(question: questionLabel, answer: fallbackAnswer, citationSeconds: imageJPEG == nil ? bestCitation : nil, imageJPEG: imageJPEG)
                pair.scope = segment != nil ? "segment" : (recentOnly ? "recent" : "whole")
                pair.originalQuery = query
                self.sessions[idx].qaPairs.append(pair)
                self.saveSessions()
            }
        }
    }
    
    /// 全堂课智能段落检索（支持 90 分钟完整课堂检索）
    public func retrieveRelevantSegments(in segments: [TranscriptSegment], query: String, maxTotalChars: Int = 12000) -> [TranscriptSegment] {
        ClassroomQuestionContext.retrieve(segments, query: query, budget: maxTotalChars)
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
    
    // MARK: - 课表草稿导入、比对与事务提交
    
    public var lastCommittedTimetable: TimetableData? = nil
    public var lastCommittedCourses: [Course]? = nil
    private var lastCommittedDeletedCourses: [Course]? = nil
    
    public func parseTimetableDraft(data: Data) throws -> TimetableImportDraft {
        return try TimetableEngine.parseTimetableDraft(data: data)
    }
    
    public func reconcileCourses(draft: TimetableImportDraft) -> TimetableImportDraft {
        var updated = draft
        for i in 0..<updated.items.count {
            let itemName = updated.items[i].editedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = courses.first(where: { $0.name == itemName && $0.semester == draft.semester && $0.source == .timetable }) {
                updated.items[i].action = .matchExisting
                updated.items[i].matchedCourseId = existing.id
                if updated.items[i].teacher.isEmpty && !existing.teacher.isEmpty {
                    updated.items[i].teacher = existing.teacher
                }
                if updated.items[i].room.isEmpty && !existing.room.isEmpty {
                    updated.items[i].room = existing.room
                }
            } else {
                updated.items[i].action = .create
                updated.items[i].matchedCourseId = nil
                if let deleted = deletedTimetableCourses.first(where: { $0.name == itemName && $0.semester == draft.semester }) {
                    updated.items[i].deletedCourseId = deleted.id
                    updated.items[i].restoreDeletedCourse = true
                }
            }
        }
        return updated
    }
    
    @discardableResult
    public func commitTimetableImport(draft: TimetableImportDraft) -> Bool {
        do {
            let state = try makeCourseTimetableState(courses: courses, timetable: timetable).importing(draft)
            try state.write(to: courseTimetableURL)
            lastCommittedCourses = state.previousImport?.courses
            lastCommittedTimetable = state.previousImport?.timetable
            lastCommittedDeletedCourses = state.previousImport?.deletedCourses
            deletedTimetableCourses = state.deletedCourses
            courses = state.current.courses
            timetable = state.current.timetable
            errorMessage = ""
            updateCourseSuggestion()
            return true
        } catch {
            errorMessage = "课表导入失败，原课表保留：\(error.localizedDescription)"
            return false
        }
    }

    public func createCourse(name: String, teacher: String = "", room: String = "") {
        let colors = ["#007AFF", "#34C759", "#FF9500", "#AF52DE", "#FF2D55", "#5856D6", "#00C7BE", "#32ADE6"]
        let newC = Course(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            teacher: teacher,
            room: room,
            colorHex: colors[courses.count % colors.count],
            source: .manual,
            status: .active
        )
        courses.append(newC)
        saveCourses()
        updateCourseSuggestion()
    }

    public func syncCoursesFromTimetable() {
        let timetableCourses = TimetableEngine.coursesFrom(slots: timetable.slots)
        for pc in timetableCourses {
            if let existingIdx = courses.firstIndex(where: { $0.name == pc.name && $0.source == .timetable && $0.semester == pc.semester }) {
                if !pc.teacher.isEmpty { courses[existingIdx].teacher = pc.teacher }
                if !pc.room.isEmpty { courses[existingIdx].room = pc.room }
            } else {
                courses.append(pc)
            }
        }
        saveCourses()
        updateCourseSuggestion()
    }

    public func cleanupUnusedCourses() {
        let activeCourseIdsWithSessions = Set(sessions.compactMap { $0.courseId })
        let timetableCourseNames = Set(timetable.slots.map { $0.courseName })
        courses.removeAll { c in
            c.source == .timetable && !activeCourseIdsWithSessions.contains(c.id) && !timetableCourseNames.contains(c.name)
        }
        saveCourses()
        updateCourseSuggestion()
    }

    public func rollbackTimetableImport() {
        guard let oldCourses = lastCommittedCourses, let oldTable = lastCommittedTimetable else { return }
        let state = CourseTimetableState(current: CourseTimetableSnapshot(courses: oldCourses, timetable: oldTable),
            previousImport: nil, deletedCourses: lastCommittedDeletedCourses ?? deletedTimetableCourses)
        do {
            try state.write(to: courseTimetableURL)
            courses = oldCourses
            timetable = oldTable
            lastCommittedCourses = nil
            lastCommittedTimetable = nil
            lastCommittedDeletedCourses = nil
            deletedTimetableCourses = state.deletedCourses
            updateCourseSuggestion()
        } catch { errorMessage = "撤销保存失败：\(error.localizedDescription)" }
    }

    public func importTimetable(data: Data) throws {
        let draft = try parseTimetableDraft(data: data)
        let reconciled = reconcileCourses(draft: draft)
        guard commitTimetableImport(draft: reconciled) else {
            throw NSError(domain: "TimetableError", code: 4, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }

    public func deleteCourse(course: Course, purgeAllData: Bool = false) {
        let state = makeCourseTimetableState(courses: courses, timetable: timetable).removing(course)
        do { try state.write(to: courseTimetableURL) }
        catch { errorMessage = "课程删除保存失败：\(error.localizedDescription)"; return }
        courses = state.current.courses
        timetable = state.current.timetable
        deletedTimetableCourses = state.deletedCourses

        if purgeAllData {
            let sessionsToDelete = sessions.filter { $0.courseId == course.id }
            for session in sessionsToDelete {
                deleteSession(session, deleteCloudCopy: false)
            }
        } else {
            for i in 0..<sessions.count {
                if sessions[i].courseId == course.id {
                    sessions[i].courseId = nil
                }
            }
            saveSessions()
        }
        
        saveCourses()
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
        finishOfflineTranscription(sessionId: session.id)
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
        for attachment in session.attachments {
            try? FileManager.default.removeItem(at: attachmentURL(attachment))
        }
    }

    private func formatDuration(_ sec: TimeInterval) -> String {
        let whole = Int(sec)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
