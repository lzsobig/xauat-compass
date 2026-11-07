import AVFoundation
import Speech
import SwiftUI

struct LessonRecording: Codable, Identifiable {
    let id: UUID
    let date: Date
    var title: String
    var transcript = ""
    var marks: [TimeInterval] = []
}

private final class AudioCapture {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var writeFailed = false

    init(file: AVAudioFile) { self.file = file }

    func append(_ buffer: AVAudioPCMBuffer) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        guard let file = file, !writeFailed else { return nil }
        do {
            try file.write(from: buffer)
            request?.append(buffer)
            return nil
        } catch {
            writeFailed = true
            return error
        }
    }

    func recognize(_ next: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        defer { lock.unlock() }
        request?.endAudio()
        request = next
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        request?.endAudio()
        request = nil
        file = nil
    }
}

@MainActor
final class ClassroomRecorder: ObservableObject {
    @Published private(set) var recordings: [LessonRecording] = []
    @Published private(set) var current: LessonRecording?
    @Published private(set) var paused = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var liveText = ""
    @Published private(set) var speechStatus = ""
    @Published private(set) var error = ""
    @Published private(set) var starting = false

    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClassroomRecordings", isDirectory: true)
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var capture: AudioCapture?
    private var speechTask: SFSpeechRecognitionTask?
    private var speechEpoch = UUID()
    private var speechStartedAt: Date?
    private var speechEnabled = false
    private var tick: Timer?
    private var runStart: TimeInterval?
    private var elapsedBase: TimeInterval = 0
    private var player: AVAudioPlayer?

    init() { reloadRecordings() }

    func audioURL(_ recording: LessonRecording) -> URL {
        root.appendingPathComponent(recording.id.uuidString + ".caf")
    }

    private func metadataURL(_ recording: LessonRecording) -> URL {
        root.appendingPathComponent(recording.id.uuidString + ".json")
    }

    private func reloadRecordings() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            recordings = files.filter { $0.pathExtension == "json" }.compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let recording = try? JSONDecoder().decode(LessonRecording.self, from: data),
                      FileManager.default.fileExists(atPath: audioURL(recording).path) else { return nil }
                return recording
            }.sorted { $0.date > $1.date }
        } catch {
            self.error = "无法读取本机录音：" + error.localizedDescription
        }
    }

    private func persist(_ recording: LessonRecording) throws {
        try JSONEncoder().encode(recording).write(to: metadataURL(recording), options: .atomic)
    }

    func start(title: String, transcribe: Bool) async {
        guard current == nil, !starting else { return }
        starting = true
        defer { starting = false }
        error = ""
        let audioSession = AVAudioSession.sharedInstance()
        let allowed = await withCheckedContinuation { continuation in
            audioSession.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard allowed else {
            error = "请在系统设置中允许使用麦克风"
            return
        }
        if transcribe {
            speechEnabled = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        } else {
            speechEnabled = false
        }
        speechStatus = transcribe && !speechEnabled ? "语音识别未授权，仍会保存录音" : ""
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let recording = LessonRecording(id: UUID(), date: Date(), title: name.isEmpty ? "课堂录音" : name)
        do {
            player?.stop()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                error = "没有可用的麦克风输入"
                try? audioSession.setActive(false)
                return
            }
            let file = try AVAudioFile(forWriting: audioURL(recording), settings: format.settings,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            let sink = AudioCapture(file: file)
            capture = sink
            try persist(recording)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                if let failure = sink.append(buffer) {
                    DispatchQueue.main.async { self?.handleWriteFailure(failure) }
                }
            }
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }
            current = recording
            paused = false
            elapsedBase = 0
            elapsed = 0
            liveText = ""
            runStart = ProcessInfo.processInfo.systemUptime
            startSpeech()
            tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateClock() }
            }
        } catch {
            capture?.close()
            capture = nil
            try? FileManager.default.removeItem(at: audioURL(recording))
            try? FileManager.default.removeItem(at: metadataURL(recording))
            try? audioSession.setActive(false)
            self.error = "无法开始录音：" + error.localizedDescription
        }
    }

    private func updateClock() {
        elapsed = elapsedBase + (runStart.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
        if let start = speechStartedAt, Date().timeIntervalSince(start) >= 45 {
            finishSpeech()
            startSpeech()
        }
    }

    private func startSpeech() {
        guard speechEnabled, let recognizer = recognizer, recognizer.isAvailable else {
            if speechEnabled { speechStatus = "语音识别暂不可用，录音仍在保存" }
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let epoch = UUID()
        speechEpoch = epoch
        speechStartedAt = Date()
        speechStatus = "正在实时转写"
        capture?.recognize(request)
        speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let finished = result?.isFinal == true
            DispatchQueue.main.async {
                guard let self = self, self.speechEpoch == epoch else { return }
                if let text = text { self.liveText = text }
                if finished || error != nil {
                    self.finishSpeech()
                    if error != nil {
                        self.speechStatus = "转写暂时中断，录音仍在保存"
                        self.speechStartedAt = Date().addingTimeInterval(-35)
                    } else {
                        self.startSpeech()
                    }
                }
            }
        }
    }

    private func finishSpeech() {
        speechEpoch = UUID()
        speechStartedAt = nil
        capture?.recognize(nil)
        speechTask?.cancel()
        speechTask = nil
        if var recording = current, !liveText.isEmpty {
            recording.transcript += (recording.transcript.isEmpty ? "" : "\n") + liveText
            current = recording
            do { try persist(recording) }
            catch { self.error = "转写文字未保存：" + error.localizedDescription }
        }
        liveText = ""
    }

    func pause() {
        guard current != nil, !paused else { return }
        engine.pause()
        updateClock()
        elapsedBase = elapsed
        runStart = nil
        paused = true
        finishSpeech()
    }

    func resume() {
        guard current != nil, paused else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            paused = false
            runStart = ProcessInfo.processInfo.systemUptime
            startSpeech()
        } catch { self.error = "无法继续录音：" + error.localizedDescription }
    }

    func mark() {
        guard var recording = current, !paused else { return }
        let at = elapsedBase + (runStart.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
        recording.marks.append(at)
        do {
            try persist(recording)
            current = recording
        } catch { self.error = "重点未保存：" + error.localizedDescription }
    }

    private func handleWriteFailure(_ failure: Error) {
        guard current != nil else { return }
        stop()
        error = "录音写入中断，已保留此前写入的音频：" + failure.localizedDescription
    }

    func stop() {
        guard current != nil else { return }
        tick?.invalidate()
        tick = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        finishSpeech()
        capture?.close()
        capture = nil
        current = nil
        paused = false
        runStart = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        reloadRecordings()
    }

    func togglePlayback(_ recording: LessonRecording) {
        guard current == nil else { return }
        let url = audioURL(recording)
        if player?.url == url, player?.isPlaying == true {
            player?.pause()
            return
        }
        do {
            if player?.url != url { player = try AVAudioPlayer(contentsOf: url) }
            try AVAudioSession.sharedInstance().setCategory(.playback)
            guard player?.play() == true else { throw CocoaError(.fileReadCorruptFile) }
        } catch { self.error = "无法播放录音：" + error.localizedDescription }
    }
}

struct ContentView: View {
    @StateObject private var recorder = ClassroomRecorder()
    @State private var title = ""
    @State private var selection: LessonRecording?

    var body: some View {
        NavigationView {
            List {
                if let current = recorder.current {
                    Section {
                        Text(current.title).font(.headline)
                        Text(time(recorder.elapsed)).font(.system(size: 38, weight: .semibold, design: .monospaced))
                        HStack {
                            Button(recorder.paused ? "继续" : "暂停") {
                                recorder.paused ? recorder.resume() : recorder.pause()
                            }
                            Button("标记重点") { recorder.mark() }.disabled(recorder.paused)
                            Spacer()
                            Button("结束", role: .destructive) { recorder.stop() }
                        }
                        .buttonStyle(.borderless)
                        if !current.marks.isEmpty {
                            Text(current.marks.map(time).joined(separator: " · ")).foregroundStyle(.secondary)
                        }
                    }
                    if !recorder.speechStatus.isEmpty {
                        Section("实时转写") {
                            Text(recorder.paused ? "已暂停" : recorder.speechStatus).foregroundStyle(.secondary)
                            if !current.transcript.isEmpty { Text(current.transcript).textSelection(.enabled) }
                            if !recorder.liveText.isEmpty { Text(recorder.liveText).textSelection(.enabled) }
                        }
                    }
                } else {
                    Section {
                        TextField("课堂名称", text: $title)
                        Button { start(true) } label: { Label("实时转写", systemImage: "waveform") }
                        Button { start(false) } label: { Label("仅录音", systemImage: "mic") }
                    }
                    .disabled(recorder.starting)
                }

                if !recorder.error.isEmpty { Text(recorder.error).foregroundStyle(.red) }

                Section("本机录音") {
                    if recorder.recordings.isEmpty { Text("暂无录音").foregroundStyle(.secondary) }
                    ForEach(recorder.recordings) { recording in
                        Button { selection = recording } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recording.title).foregroundStyle(.primary)
                                Text(recording.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(recorder.current != nil)
                    }
                }
            }
            .navigationTitle("建大课堂录音")
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                if notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                    recorder.pause()
                }
            }
            .sheet(item: $selection) { recording in
                NavigationView {
                    List {
                        Button { recorder.togglePlayback(recording) } label: {
                            Label("播放 / 暂停", systemImage: "playpause")
                        }
                        if !recorder.error.isEmpty { Text(recorder.error).foregroundStyle(.red) }
                        if !recording.marks.isEmpty {
                            Section("重点") { Text(recording.marks.map(time).joined(separator: " · ")) }
                        }
                        Section("转写") {
                            Text(recording.transcript.isEmpty ? "暂无转写文字" : recording.transcript)
                                .textSelection(.enabled)
                        }
                    }
                    .navigationTitle(recording.title)
                    .toolbar { Button("完成") { selection = nil } }
                }
                .navigationViewStyle(.stack)
            }
        }
        .navigationViewStyle(.stack)
    }

    private func start(_ transcribe: Bool) {
        Task { await recorder.start(title: title, transcribe: transcribe) }
    }

    private func time(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
