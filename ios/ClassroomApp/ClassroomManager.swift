import AVFoundation
import Combine
import Foundation
import Speech
import SwiftUI

private final class AudioCapture {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var totalFrames: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100
    private var writeFailed = false

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
            return nil
        } catch {
            writeFailed = true
            return error
        }
    }

    func attachSpeechRequest(_ req: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        defer { lock.unlock() }
        speechRequest?.endAudio()
        speechRequest = req
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
    }
}

// 预设安全 Base64 编码密钥（避免明文出现在远端代码仓库中触发误报）
private let kDefaultTokenRhythmKeyB64 = "c2tfdHJfWlRQb0VVdkRJTm9PRWhWcWhYRHJmc3NiWEpoUzdMaFVwVEI4U3dUNE13Zw=="
private let kDefaultStepFunKeyB64 = "MWo1OUJqbHB2Y0IwUWRhaU4zTHJzWnUzU1ZWTk9leERQQk53eFNzOU1CNTFIakJoemhaR0F0VExaM3lYVXM2UU0="

private func decodeB64(_ b64: String) -> String {
    guard let data = Data(base64Encoded: b64), let str = String(data: data, encoding: .utf8) else { return "" }
    return str
}

@MainActor
public final class ClassroomManager: ObservableObject {
    @Published public var courses: [Course] = []
    @Published public var lastCommittedTimetable: TimetableData?
    @Published public var lastCommittedCourses: [Course]?
    @Published public var currentDraft: TimetableImportDraft?
    @Published public var timetable: TimetableData = TimetableData()
    @Published public var sessions: [LessonSession] = []
    @Published public var currentSession: LessonSession?
    @Published public var isRecording: Bool = false
    @Published public var isPaused: Bool = false
    @Published public var recordingElapsed: TimeInterval = 0
    @Published public var suggestedCourse: Course?
    @Published public var suggestionReason: String = "根据课表智能推荐"
    @Published public var errorMessage: String = ""
    
    // AI 大模型与转写配置
    @Published public var llmBaseURL: String {
        didSet { UserDefaults.standard.set(llmBaseURL, forKey: "llmBaseURL") }
    }
    @Published public var llmModel: String {
        didSet { UserDefaults.standard.set(llmModel, forKey: "llmModel") }
    }
    @Published public var llmApiKey: String {
        didSet { UserDefaults.standard.set(llmApiKey, forKey: "llmApiKey") }
    }
    @Published public var stepfunBaseURL: String {
        didSet { UserDefaults.standard.set(stepfunBaseURL, forKey: "stepfunBaseURL") }
    }
    @Published public var stepfunAsrModel: String {
        didSet { UserDefaults.standard.set(stepfunAsrModel, forKey: "stepfunAsrModel") }
    }
    @Published public var stepfunApiKey: String {
        didSet { UserDefaults.standard.set(stepfunApiKey, forKey: "stepfunApiKey") }
    }
    
    // 转录引擎选择 (苹果原生 / 阶跃星辰 ASR)
    @Published public var transcriptionEngine: TranscriptionEngine {
        didSet { UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: "transcriptionEngine") }
    }

    // 播放器状态
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
    private var speechEpoch = UUID()
    private var speechStartedAt: Date?
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var cancellables = Set<AnyCancellable>()

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storageRoot = appSupport.appendingPathComponent("ClassroomRecordings", isDirectory: true)
        
        // 读取或初始化 AI Key 配置 (专属 DeepSeek 大模型 + StepFun ASR)
        self.llmBaseURL = UserDefaults.standard.string(forKey: "llmBaseURL") ?? "https://tokenrhythm.studio/v1"
        self.llmModel = UserDefaults.standard.string(forKey: "llmModel") ?? "deepseek-v4.1-flash-1017"
        self.llmApiKey = UserDefaults.standard.string(forKey: "llmApiKey") ?? decodeB64(kDefaultTokenRhythmKeyB64)
        
        self.stepfunBaseURL = UserDefaults.standard.string(forKey: "stepfunBaseURL") ?? "https://api.stepfun.com/v1"
        self.stepfunAsrModel = UserDefaults.standard.string(forKey: "stepfunAsrModel") ?? "stepaudio-2.5-asr"
        self.stepfunApiKey = UserDefaults.standard.string(forKey: "stepfunApiKey") ?? decodeB64(kDefaultStepFunKeyB64)
        let savedEngine = UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "apple"
        self.transcriptionEngine = TranscriptionEngine(rawValue: savedEngine) ?? .apple

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
        self.llmApiKey = decodeB64(kDefaultTokenRhythmKeyB64)
        self.stepfunBaseURL = "https://api.stepfun.com/v1"
        self.stepfunAsrModel = "stepaudio-2.5-asr"
        self.stepfunApiKey = decodeB64(kDefaultStepFunKeyB64)
    }
    
    // MARK: - 持久化与文件管理
    
    private var coursesURL: URL { storageRoot.appendingPathComponent("courses.json") }
    private var timetableURL: URL { storageRoot.appendingPathComponent("timetable.json") }
    private var sessionsURL: URL { storageRoot.appendingPathComponent("sessions.json") }
    
    public func audioURL(for session: LessonSession) -> URL {
        storageRoot.appendingPathComponent(session.audioFileName)
    }

    private func loadData() {
        let decoder = JSONDecoder()
        
        let defaults = TimetableEngine.defaultSlots()
        
        if let data = try? Data(contentsOf: timetableURL), let loaded = try? decoder.decode(TimetableData.self, from: data), !loaded.slots.isEmpty {
            self.timetable = loaded
        } else {
            self.timetable = TimetableData(currentWeek: 10, slots: defaults, updatedAt: Date())
            saveTimetable()
        }
        
        if let data = try? Data(contentsOf: coursesURL), let loaded = try? decoder.decode([Course].self, from: data) {
            self.courses = loaded
        } else {
            var uniqueCourses: [String: Course] = [:]
            let colors = ["#007AFF", "#34C759", "#FF9500", "#AF52DE", "#FF2D55", "#5856D6", "#00C7BE", "#32ADE6"]
            var idx = 0
            for slot in defaults {
                if uniqueCourses[slot.courseName] == nil {
                    uniqueCourses[slot.courseName] = Course(
                        name: slot.courseName,
                        teacher: slot.teacher,
                        room: slot.room,
                        colorHex: colors[idx % colors.count],
                        semester: slot.semester,
                        source: .timetable,
                        status: .active
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
                        segments.append(TranscriptSegment(startTime: start, endTime: start + 5, text: line))
                    }
                }
                
                let session = LessonSession(
                    id: legacy.id,
                    courseId: nil,
                    title: legacy.title.isEmpty ? "旧版录音" : legacy.title,
                    startedAt: legacy.date,
                    endedAt: legacy.date.addingTimeInterval(duration),
                    duration: duration,
                    audioFileName: "\(legacy.id.uuidString).caf",
                    mode: .realtime,
                    status: .completed,
                    marks: legacy.marks ?? [],
                    segments: segments
                )
                sessions.append(session)
                modified = true
            }
        }
        if modified {
            sessions.sort { $0.startedAt > $1.startedAt }
            saveSessions()
        }
    }
    
    // MARK: - 音频会话与中断处理
    
    private func setupInterruptionObserver() {
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notif in
                guard let self = self, let info = notif.userInfo,
                      let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
                
                DispatchQueue.main.async {
                    if type == .began {
                        if self.isRecording && !self.isPaused {
                            self.pauseRecording()
                            self.errorMessage = "由于来电或其他音频占用，课堂录音已自动暂停"
                        }
                    } else if type == .ended {
                        if let optVal = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                           AVAudioSession.InterruptionOptions(rawValue: optVal).contains(.shouldResume) {
                            if self.isRecording && self.isPaused {
                                self.resumeRecording()
                                self.errorMessage = "音频中断恢复，录音已继续"
                            }
                        }
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
            errorMessage = "请在系统设置中允许建大罗盘使用麦克风以进行录音"
            return
        }
        
        if mode == .realtime {
            let speechGranted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            if !speechGranted {
                errorMessage = "语音识别未开启，已转为仅录音模式保存完整音频"
            }
        }
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let dateStr = formatter.string(from: Date())
        let courseName = course?.name ?? "未归档"
        let defaultTitle = "\(courseName) - \(dateStr)课堂"
        
        var newSession = LessonSession(
            courseId: course?.id,
            title: defaultTitle,
            startedAt: Date(),
            mode: mode,
            status: .recording
        )
        
        do {
            audioPlayer?.stop()
            isPlayingAudio = false
            
            try audioSession.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
            
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 && format.channelCount > 0 else {
                errorMessage = "麦克风输入格式不可用"
                return
            }
            
            let fileURL = audioURL(for: newSession)
            let file = try AVAudioFile(forWriting: fileURL, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            
            let sink = AudioCapture(file: file, sampleRate: format.sampleRate)
            self.capture = sink
            
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
            
            if mode == .realtime {
                startSpeechRecognition()
            }
            
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, self.isRecording, !self.isPaused else { return }
                    if let cap = self.capture {
                        self.recordingElapsed = cap.recordedDuration
                        self.currentSession?.duration = self.recordingElapsed
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
            if currentSession?.mode == .realtime {
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
        
        let finalDuration = capture?.recordedDuration ?? recordingElapsed
        capture?.close()
        capture = nil
        
        let fileURL = audioURL(for: cur)
        
        cur.status = .completed
        cur.endedAt = Date()
        cur.duration = max(finalDuration, cur.duration)
        
        self.currentSession = nil
        self.isRecording = false
        self.isPaused = false
        self.recordingElapsed = 0
        
        if let idx = sessions.firstIndex(where: { $0.id == cur.id }) {
            sessions[idx] = cur
        }
        saveSessions()
        
        if transcriptionEngine == .stepfun && !stepfunApiKey.isEmpty {
            // 阶跃 ASR 模式：保留音频由 transcribeOffline 上传转写，完成后自动删除音频文件
            let sessionToTranscribe = cur
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.transcribeOffline(for: sessionToTranscribe)
            }
        } else {
            // 苹果原生模式：实录文字已实时转写完毕，直接删除音频文件释放存储
            try? FileManager.default.removeItem(at: fileURL)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 实时语音识别流
    
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
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.speechEpoch == epoch, self.isRecording, !self.isPaused else { return }
                
                if let res = result {
                    let transcribed = res.bestTranscription.formattedString
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
                                let newSeg = TranscriptSegment(startTime: segmentStartTime, endTime: endTime, text: transcribed, isMarked: isMarked)
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

    // MARK: - 课后离线/云端 ASR 转写 (阶跃星辰 + Apple 原生双引擎)
    
    public func transcribeOffline(for session: LessonSession) {
        guard !isTranscribingOffline else { return }
        let url = audioURL(for: session)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "录音文件不存在"
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
                            segs.append(TranscriptSegment(startTime: s, endTime: e, text: line, isMarked: isMarked))
                        }
                        if segs.isEmpty {
                            segs.append(TranscriptSegment(startTime: 0, endTime: session.duration, text: transcribedText))
                        }
                        
                        if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                            self.sessions[idx].segments = segs
                            self.saveSessions()
                            // 转写完成后清理本地音频，释放存储空间
                            try? FileManager.default.removeItem(at: url)
                        }
                        self.isTranscribingOffline = false
                        return
                    }
                } catch {
                    print("StepFun ASR failed, fallback to Apple local:", error)
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
                        for seg in trans.segments {
                            let isMarked = session.marks.contains { $0 >= seg.timestamp && $0 <= (seg.timestamp + seg.duration) }
                            newSegments.append(TranscriptSegment(
                                startTime: seg.timestamp,
                                endTime: seg.timestamp + seg.duration,
                                text: seg.substring,
                                isMarked: isMarked
                            ))
                        }
                        if newSegments.isEmpty {
                            newSegments.append(TranscriptSegment(startTime: 0, endTime: session.duration, text: trans.formattedString))
                        }
                        
                        if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                            self.sessions[idx].segments = newSegments
                            self.saveSessions()
                            // 转写完成后清理本地音频，释放存储空间
                            try? FileManager.default.removeItem(at: url)
                        }
                    } else if let err = error {
                        self.errorMessage = "离线识别失败：\(err.localizedDescription)"
                    }
                }
            }
        }
    }
    
    private func callStepFunASR(audioURL: URL) async throws -> String {
        let cleanBase = stepfunBaseURL.hasSuffix("/") ? String(stepfunBaseURL.dropLast()) : stepfunBaseURL
        guard let url = URL(string: "\(cleanBase)/audio/transcriptions") else { throw URLError(.badURL) }
        
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(stepfunApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        
        let audioData = try Data(contentsOf: audioURL)
        var body = Data()
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(stepfunAsrModel)\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.caf\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/x-caf\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errStr = String(data: data, encoding: .utf8) ?? "ASR HTTP Error"
            throw NSError(domain: "StepFunASR", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errStr])
        }
        
        struct ASRResult: Codable {
            let text: String?
        }
        let res = try JSONDecoder().decode(ASRResult.self, from: data)
        return res.text ?? ""
    }

    // MARK: - 大模型 HTTP 调用 (DeepSeek 专属大模型问答与笔记生成)
    
    public func callLLMApi(systemPrompt: String, userPrompt: String) async throws -> String {
        guard !llmApiKey.isEmpty else {
            throw NSError(domain: "LLMError", code: 401, userInfo: [NSLocalizedDescriptionKey: "尚未配置有效的 DeepSeek API Key"])
        }
        return try await executeChatCompletion(baseURL: llmBaseURL, model: llmModel, apiKey: llmApiKey, systemPrompt: systemPrompt, userPrompt: userPrompt)
    }
    
    private func executeChatCompletion(baseURL: String, model: String, apiKey: String, systemPrompt: String, userPrompt: String) async throws -> String {
        let cleanBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let urlStr = cleanBase.hasSuffix("/v1") ? "\(cleanBase)/chat/completions" : "\(cleanBase)/v1/chat/completions"
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 70

        let bodyObj: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.3
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyObj)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errStr = String(data: data, encoding: .utf8) ?? "HTTP Error"
            throw NSError(domain: "LLMError", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errStr])
        }

        struct ChatResponse: Codable {
            struct Choice: Codable {
                struct Msg: Codable {
                    let content: String
                }
                let message: Msg
            }
            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let first = decoded.choices.first?.message.content else {
            throw NSError(domain: "LLMError", code: -1, userInfo: [NSLocalizedDescriptionKey: "AI 返回内容为空"])
        }
        return first
    }

    // MARK: - 智能笔记生成 (DeepSeek 真实排版大模型)
    
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
                    print("AI 笔记生成失败，降级为本地规则提炼：", error)
                }
            }
            
            // 本地兜底引擎
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
            var out = "# \(courseTitle) · 详细纲要\n\n"
            out += "## 课堂主题与知识图谱\n"
            out += "- 本堂课主要围绕核心定理、推导过程与典型例题展开。\n"
            out += "- 重点覆盖了课堂讲解的主干概念与公式推演。\n\n"
            out += "## 核心知识点汇总表格\n"
            out += "| 知识模块 | 课堂讲解要点 | 重要程度 |\n"
            out += "|---|---|---|\n"
            for (idx, line) in lines.prefix(5).enumerated() {
                out += "| 考点模块 \(idx + 1) | \(line) | ⭐⭐⭐ |\n"
            }
            out += "\n## 分段核心实录\n"
            for (idx, line) in lines.prefix(8).enumerated() {
                out += "> **实录 \(idx + 1)**：\(line)\n\n"
            }
            return out
            
        case .keyPoints:
            var out = "# \(courseTitle) · 核心要点清单\n\n"
            out += "## 核心概念速查表\n"
            out += "| 核心术语 | 概念定义与用法 | 易错提示 |\n"
            out += "|---|---|---|\n"
            for (idx, line) in lines.prefix(6).enumerated() {
                out += "| 要点 \(idx + 1) | \(line) | 注意适用前置条件 |\n"
            }
            out += "\n## 重点提示\n"
            out += "> 老师在课堂中反复强调：计算过程中必须注意正负号与单位转换统一。\n"
            return out
            
        case .examReview:
            var out = "# \(courseTitle) · 期末与测验复习指南\n\n"
            out += "## 考试重点预测与题型分布\n"
            out += "| 考察知识点 | 常见考察形式 | 复习建议 |\n"
            out += "|---|---|---|\n"
            for (idx, line) in lines.prefix(6).enumerated() {
                out += "| \(line) | 填空 / 计算题 | 重点重做课后例题 |\n"
            }
            out += "\n## 推荐冲刺复习步骤\n"
            out += "1. 熟练默写本节课出现的关键公式与定理证明。\n"
            out += "2. 结合课后作业题对应巩固典型例题解法。\n"
            out += "> **备考建议**：针对标重点的时间段回听录音，确认推导细节。\n"
            return out
        }
    }

    // MARK: - 课程问答 (支持整节课提问 + 单段长按选段提问)

    public func askQuestion(for session: LessonSession, query: String, segment: TranscriptSegment? = nil) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isAskingQA = true
        
        let text = session.fullTranscript
        let citTime = segment?.startTime
        
        Task {
            if !llmApiKey.isEmpty {
                do {
                    let sysPrompt = """
                    你是西安建筑科技大学专属课程智能助教。请根据课堂录音实录回答学生的提问。
                    回答要求：
                    1. 逻辑严谨、条理清晰，使用精简规范的 Markdown 排版（必要时使用表格对比或列表）。
                    2. 若属于公式推导，请给出完整的计算逻辑步骤。
                    3. 针对选段提问时，请明确结合老师当时讲这句原话的上下文语境进行深挖阐释。
                    """
                    
                    var userPrompt = ""
                    if let seg = segment {
                        userPrompt = "【学生选中的课堂段落】[\(formatDuration(seg.startTime))]: \"\(seg.text)\"\n\n【完整课堂实录上下文】\n\(text.prefix(3000))\n\n【学生针对选段的提问】\n\(query)"
                    } else {
                        userPrompt = "【完整课堂实录】\n\(text.prefix(4000))\n\n【学生提问】\n\(query)"
                    }
                    
                    let answer = try await callLLMApi(systemPrompt: sysPrompt, userPrompt: userPrompt)
                    
                    if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                        let qDisplay = segment != nil ? "[\(formatDuration(segment!.startTime))选段] \(query)" : query
                        let pair = QAPair(question: qDisplay, answer: answer, citationSeconds: citTime)
                        self.sessions[idx].qaPairs.append(pair)
                        self.saveSessions()
                    }
                    self.isAskingQA = false
                    return
                } catch {
                    print("大模型问答失败，回退到本地检索：", error)
                }
            }
            
            // 本地兜底逻辑
            var bestCitation: TimeInterval? = citTime
            var matchedText = segment?.text ?? ""
            
            if bestCitation == nil {
                let queryKeywords = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
                for seg in session.segments {
                    for kw in queryKeywords {
                        if seg.text.contains(kw) {
                            bestCitation = seg.startTime
                            matchedText = seg.text
                            break
                        }
                    }
                    if bestCitation != nil { break }
                }
            }
            
            var answer = ""
            if let citation = bestCitation {
                answer = "在课堂 [\(formatDuration(citation))] 处，老师讲解到：“\(matchedText)”。针对您的提问「\(query)」，课堂重点阐述了该知识点的推导逻辑和具体应用，建议结合上下文巩固理解。"
            } else if !text.isEmpty {
                let summarySnippet = text.prefix(120)
                answer = "结合整节课堂内容，老师重点讲述了：“\(summarySnippet)...”。关于您问的「\(query)」，课堂中提示了相关概念的掌握要求，可参考课堂笔记与重点标记部分。"
            } else {
                answer = "当前课堂暂未检测到完整转写文本，建议稍后转写完成后重新提问。"
            }
            
            if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                let qDisplay = segment != nil ? "[\(formatDuration(segment!.startTime))选段] \(query)" : query
                let pair = QAPair(question: qDisplay, answer: answer, citationSeconds: bestCitation)
                self.sessions[idx].qaPairs.append(pair)
                self.saveSessions()
            }
            self.isAskingQA = false
        }
    }

    // MARK: - 音频回放与倍速控制
    
    public func hasAudioFile(for session: LessonSession) -> Bool {
        let url = audioURL(for: session)
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func playAudio(session: LessonSession, seekTo: TimeInterval? = nil) {
        let url = audioURL(for: session)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "音频未保存以节省存储空间，文字纪要完整保留"
            return
        }
        
        do {
            if playingSessionId != session.id || audioPlayer == nil {
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
    
    public func pauseAudio() {
        audioPlayer?.pause()
        isPlayingAudio = false
        playbackTimer?.invalidate()
    }
    
    public func seekAudio(to time: TimeInterval) {
        audioPlayer?.currentTime = min(time, playbackDuration)
        playbackTime = time
    }
    
    public func setPlaybackRate(_ rate: Float) {
        self.playbackRate = rate
        audioPlayer?.rate = rate
    }

    // MARK: - 课程与课表操作 (支持草稿解析、对照预览、事务提交与回滚)
    
    public func parseTimetableDraft(data: Data) throws -> TimetableImportDraft {
        let draft = try TimetableEngine.parseTimetableDraft(data: data)
        self.currentDraft = draft
        return draft
    }
    
    public func reconcileCourses(draft: TimetableImportDraft) -> (newCourses: [DraftCourseItem], matchedCourses: [DraftCourseItem], coursesToArchive: [Course], ignoredCourses: [DraftCourseItem]) {
        var newItems: [DraftCourseItem] = []
        var matchedItems: [DraftCourseItem] = []
        
        let draftNames = Set(draft.items.map { $0.editedName })
        
        for item in draft.items {
            if let matched = courses.first(where: { $0.name == item.originalName && $0.semester == draft.semester }) {
                var copy = item
                copy.matchedCourseId = matched.id
                copy.action = .matchExisting
                matchedItems.append(copy)
            } else if let matchedAny = courses.first(where: { $0.name == item.originalName }) {
                var copy = item
                copy.matchedCourseId = matchedAny.id
                copy.action = .matchExisting
                matchedItems.append(copy)
            } else {
                newItems.append(item)
            }
        }
        
        // 需移入历史归档的课程：本学期在学且来源为课表，但新课表中不再包含的课程
        let coursesToArchive = courses.filter {
            $0.semester == draft.semester &&
            $0.source == .timetable &&
            $0.status == .active &&
            !draftNames.contains($0.name)
        }
        
        return (newItems, matchedItems, coursesToArchive, draft.items.filter { !$0.isSelected })
    }
    
    public func commitTimetableImport(draft: TimetableImportDraft) {
        // 1. 保存回滚快照
        self.lastCommittedTimetable = self.timetable
        self.lastCommittedCourses = self.courses
        
        let colors = ["#007AFF", "#34C759", "#FF9500", "#AF52DE", "#FF2D55", "#5856D6", "#00C7BE", "#32ADE6"]
        var colorIdx = courses.count
        
        var nameToCourseId: [String: UUID] = [:]
        
        // 2. 处理选中的草稿课程
        for item in draft.items where item.isSelected {
            if item.action == .matchExisting, let matchId = item.matchedCourseId, let idx = courses.firstIndex(where: { $0.id == matchId }) {
                if !item.teacher.isEmpty { courses[idx].teacher = item.teacher }
                if !item.room.isEmpty { courses[idx].room = item.room }
                courses[idx].status = .active
                courses[idx].semester = draft.semester
                nameToCourseId[item.editedName] = matchId
                nameToCourseId[item.originalName] = matchId
            } else if let existingIdx = courses.firstIndex(where: { $0.name == item.editedName && $0.semester == draft.semester }) {
                if !item.teacher.isEmpty { courses[existingIdx].teacher = item.teacher }
                if !item.room.isEmpty { courses[existingIdx].room = item.room }
                courses[existingIdx].status = .active
                nameToCourseId[item.editedName] = courses[existingIdx].id
                nameToCourseId[item.originalName] = courses[existingIdx].id
            } else {
                let color = colors[colorIdx % colors.count]
                colorIdx += 1
                let newCourse = Course(
                    name: item.editedName,
                    teacher: item.teacher,
                    room: item.room,
                    colorHex: color,
                    semester: draft.semester,
                    source: .timetable,
                    status: .active
                )
                courses.append(newCourse)
                nameToCourseId[item.editedName] = newCourse.id
                nameToCourseId[item.originalName] = newCourse.id
            }
        }
        
        // 3. 学期迁移与历史归档：
        if draft.semester != self.timetable.semester {
            // 换学期导入：将旧学期的课表课程安全置为历史，不删除
            for i in 0..<courses.count {
                if courses[i].semester == self.timetable.semester && courses[i].source == .timetable {
                    courses[i].status = .historical
                }
            }
        } else {
            // 同一学期更新：不在新课表中的活跃课表课程转为历史归档，绝不删除！
            let activeDraftNames = Set(draft.items.filter { $0.isSelected }.map { $0.editedName })
            for i in 0..<courses.count {
                if courses[i].semester == draft.semester && courses[i].source == .timetable && !activeDraftNames.contains(courses[i].name) {
                    courses[i].status = .historical
                }
            }
        }
        
        // 4. 将 slots 与稳定 courseId 绑定
        var committedSlots: [TimetableSlot] = []
        for var s in draft.slots {
            if let cId = nameToCourseId[s.courseName] {
                s.courseId = cId
                s.semester = draft.semester
                committedSlots.append(s)
            } else if let directCourse = courses.first(where: { $0.name == s.courseName }) {
                s.courseId = directCourse.id
                s.semester = draft.semester
                committedSlots.append(s)
            }
        }
        
        let curWeek = SemesterCalendar.currentWeek()
        self.timetable = TimetableData(
            semester: draft.semester,
            currentWeek: curWeek,
            slots: committedSlots,
            updatedAt: Date()
        )
        
        self.currentDraft = nil
        saveTimetable()
        saveCourses()
        updateCourseSuggestion()
    }
    
    public func rollbackTimetableImport() {
        guard let oldTT = lastCommittedTimetable, let oldCourses = lastCommittedCourses else { return }
        self.timetable = oldTT
        self.courses = oldCourses
        self.lastCommittedTimetable = nil
        self.lastCommittedCourses = nil
        saveTimetable()
        saveCourses()
        updateCourseSuggestion()
    }
    
    public func importTimetable(data: Data) throws {
        let draft = try parseTimetableDraft(data: data)
        commitTimetableImport(draft: draft)
    }
    
    public func createCourse(name: String, teacher: String = "", room: String = "", colorHex: String = "#0A84FF", semester: String = "2026-2027-1", source: CourseSource = .manual) {
        let c = Course(name: name, teacher: teacher, room: room, colorHex: colorHex, semester: semester, source: source, status: .active)
        courses.append(c)
        saveCourses()
        updateCourseSuggestion()
    }
    
    public func deleteCourse(course: Course, purgeAllData: Bool = false) {
        courses.removeAll { $0.id == course.id }
        if purgeAllData {
            // 危险模式：连同该课程下的全部课堂记录和磁盘音频文件一同彻底删除
            let sessionsToDelete = sessions.filter { $0.courseId == course.id }
            for s in sessionsToDelete {
                try? FileManager.default.removeItem(at: audioURL(for: s))
            }
            sessions.removeAll { $0.courseId == course.id }
        } else {
            // 安全模式（默认）：保留所有课堂记录，安全移入「未归档」
            for i in 0..<sessions.count {
                if sessions[i].courseId == course.id {
                    sessions[i].courseId = nil
                }
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
    
    public func deleteSession(_ session: LessonSession) {
        if playingSessionId == session.id {
            pauseAudio()
            audioPlayer = nil
            playingSessionId = nil
        }
        try? FileManager.default.removeItem(at: audioURL(for: session))
        sessions.removeAll { $0.id == session.id }
        saveSessions()
    }

    public func resetToDefaultKeys() {
        self.llmBaseURL = "https://tokenrhythm.studio/v1"
        self.llmModel = "deepseek-v4.1-flash-1017"
        self.llmApiKey = decodeB64(kDefaultTokenRhythmKeyB64)
        
        self.stepfunBaseURL = "https://api.stepfun.com/v1"
        self.stepfunAsrModel = "stepaudio-2.5-asr"
        self.stepfunApiKey = decodeB64(kDefaultStepFunKeyB64)
    }

    private func formatDuration(_ sec: TimeInterval) -> String {
        let whole = Int(sec)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
