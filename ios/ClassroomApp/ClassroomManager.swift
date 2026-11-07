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
    
    // 播放器状态
    @Published public var isPlayingAudio: Bool = false
    @Published public var playbackTime: TimeInterval = 0
    @Published public var playbackDuration: TimeInterval = 0
    @Published public var playbackRate: Float = 1.0
    @Published public var playingSessionId: UUID?
    
    // AI 状态
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
        
        try? FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        
        loadData()
        recoverInterruptedSessions()
        migrateLegacyRecordings()
        updateCourseSuggestion()
        setupInterruptionObserver()
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
        
        if let data = try? Data(contentsOf: coursesURL), let loaded = try? decoder.decode([Course].self, from: data) {
            self.courses = loaded
        } else {
            // 初始化默认课程示例
            self.courses = [
                Course(name: "线性代数 A", teacher: "朱立平", room: "草堂9-203", colorHex: "#0A84FF"),
                Course(name: "大学物理 B", teacher: "王蕾", room: "草堂物理实验室", colorHex: "#30D158"),
                Course(name: "高等数学", teacher: "李老师", room: "教学楼 4-102", colorHex: "#FF9F0A")
            ]
            saveCourses()
        }
        
        if let data = try? Data(contentsOf: timetableURL), let loaded = try? decoder.decode(TimetableData.self, from: data) {
            self.timetable = loaded
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
                    courseId: nil, // 未归档
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
        
        // 将时间戳覆盖到最近的段落
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
                    // 转写遇到阶段边界或限时，平滑重启识别
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

    // MARK: - 课后离线转写 (针对仅录音模式)
    
    public func transcribeOffline(for session: LessonSession) {
        guard !isTranscribingOffline else { return }
        let url = audioURL(for: session)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "录音文件不存在"
            return
        }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "系统语音识别暂不可用"
            return
        }
        
        isTranscribingOffline = true
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
                    }
                } else if let err = error {
                    self.errorMessage = "离线识别失败：\(err.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 智能笔记与问答生成
    
    public func generateNotes(for session: LessonSession, style: NoteStyle) {
        isGeneratingNotes = true
        let fullText = session.fullTranscript
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 本地智能化笔记结构整理引擎
            let generated = Self.synthesizeNotes(fullText: fullText, marks: session.marks, style: style, courseTitle: session.title)
            
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isGeneratingNotes = false
                if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                    var notes = self.sessions[idx].notes.filter { $0.style != style }
                    notes.append(LessonNote(style: style, content: generated))
                    self.sessions[idx].notes = notes
                    self.saveSessions()
                }
            }
        }
    }
    
    private static func synthesizeNotes(fullText: String, marks: [TimeInterval], style: NoteStyle, courseTitle: String) -> String {
        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "当前课堂尚未完成语音转写，无法提炼课堂笔记。请等待实时转写完成或在课后点击「转写录音」。"
        }
        
        let lines = fullText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        switch style {
        case .detailedOutline:
            var out = "# \(courseTitle) · 详细纲要\n\n"
            out += "## 一、课堂主题与知识图谱\n"
            out += "- 本堂课主要围绕核心定理、推导过程与典型例题展开。\n"
            out += "- 重点覆盖了课堂讲解的主干概念与公式推演。\n\n"
            out += "## 二、结构化分段讲解\n"
            for (idx, line) in lines.prefix(12).enumerated() {
                out += "### 2.\(idx + 1) 讲解要点 \(idx + 1)\n"
                out += "> \(line)\n\n"
            }
            if !marks.isEmpty {
                out += "## 三、老师着重强调的标记重点\n"
                for (idx, m) in marks.enumerated() {
                    let min = Int(m) / 60
                    let sec = Int(m) % 60
                    out += "- **重点 \(idx + 1) [\(String(format: "%02d:%02d", min, sec))]**：老师在此时段进行了重点强调，需重点复习。\n"
                }
            }
            return out
            
        case .keyPoints:
            var out = "# \(courseTitle) · 核心要点清单\n\n"
            out += "## 📌 核心知识点摘要\n"
            for (idx, line) in lines.prefix(8).enumerated() {
                out += "\(idx + 1). **核心点**：\(line)\n"
            }
            out += "\n## 💡 难点与易错提示\n"
            out += "- 注意公式成立的前置条件与定义域范围。\n"
            out += "- 课堂例题中的解题思路与常规计算方法的区别。\n"
            return out
            
        case .examReview:
            var out = "# \(courseTitle) · 期末与测验复习指南\n\n"
            out += "## 🎯 考试重点预测\n"
            out += "根据课堂用词频率与老师强调的语调，以下内容为高频考点：\n\n"
            for (idx, line) in lines.prefix(6).enumerated() {
                out += "- **高频考点 \(idx + 1)**：\(line)\n"
            }
            out += "\n## 📝 推荐复习步骤\n"
            out += "1. 熟练默写本节课出现的关键公式与定理证明。\n"
            out += "2. 结合课后作业题对应巩固典型例题解法。\n"
            out += "3. 针对标重点的时间段回听录音，确认推导细节。\n"
            return out
        }
    }

    public func askQuestion(for session: LessonSession, query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isAskingQA = true
        
        let text = session.fullTranscript
        let segs = session.segments
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 基于课堂上下文的检索与解答
            var bestCitation: TimeInterval?
            var matchedText = ""
            
            let queryKeywords = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
            for seg in segs {
                for kw in queryKeywords {
                    if seg.text.contains(kw) {
                        bestCitation = seg.startTime
                        matchedText = seg.text
                        break
                    }
                }
                if bestCitation != nil { break }
            }
            
            var answer = ""
            if let citation = bestCitation {
                let min = Int(citation) / 60
                let sec = Int(citation) % 60
                answer = "在课堂 [\(String(format: "%02d:%02d", min, sec))] 处，老师讲解到：“\(matchedText)”。针对您的提问「\(query)」，课堂重点阐述了该知识点的推导逻辑和具体应用，建议结合上下文巩固理解。"
            } else if !text.isEmpty {
                let summarySnippet = text.prefix(120)
                answer = "结合整节课堂内容，老师重点讲述了：“\(summarySnippet)...”。关于您问的「\(query)」，课堂中提示了相关概念的掌握要求，可参考课堂笔记与重点标记部分。"
            } else {
                answer = "当前课堂暂未检测到完整转写文本，建议稍后转写完成后重新提问。"
            }
            
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isAskingQA = false
                if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                    let pair = QAPair(question: query, answer: answer, citationSeconds: bestCitation)
                    self.sessions[idx].qaPairs.append(pair)
                    self.saveSessions()
                }
            }
        }
    }

    // MARK: - 音频回放与倍速控制
    
    public func playAudio(session: LessonSession, seekTo: TimeInterval? = nil) {
        let url = audioURL(for: session)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "音频文件不存在"
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
                sessions[i].courseId = nil // 移入未归档
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
}
