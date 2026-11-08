import re

pcm_to_wav_func = """
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
"""

audio_capture_replacement = """private final class AudioCapture {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var totalFrames: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100
    private var writeFailed = false
    
    // 阶跃 ASR 实时分段切片缓冲区 (重采样到 16kHz 16-bit 单声道)
    private var sliceSamples: [Int16] = []
    private var sliceStepAccumulator: Double = 0

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

    func attachSpeechRequest(_ req: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        defer { lock.unlock() }
        speechRequest?.endAudio()
        speechRequest = req
    }

    func takeCurrentSliceWavData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !sliceSamples.isEmpty else { return nil }
        let samples = sliceSamples
        sliceSamples.removeAll(keepingCapacity: true)
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
    }
}"""

for target_dir in [r'd:\antigrity\竞赛罗盘\ios\ClassroomApp', r'D:\antigrity\建大课堂录音-iOS\ios\ClassroomApp']:
    file_path = f"{target_dir}\\ClassroomManager.swift"
    with open(file_path, 'r', encoding='utf-8') as f:
        text = f.read()

    # 1. Add pcmToWav
    if 'func pcmToWav(' not in text:
        text = pcm_to_wav_func + '\n' + text

    # 2. Replace AudioCapture
    m_ac = re.search(r'private final class AudioCapture\s*\{.*?\n\}', text, re.DOTALL)
    if m_ac:
        text = text[:m_ac.start()] + audio_capture_replacement + text[m_ac.end():]
        print(f"Replaced AudioCapture in {file_path}")

    # 3. Add stepfunChunkInterval property
    if 'stepfunChunkInterval' not in text:
        target_prop = """    @Published public var transcriptionEngine: TranscriptionEngine {
        didSet { UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: "transcriptionEngine") }
    }"""
        new_prop = """    @Published public var transcriptionEngine: TranscriptionEngine {
        didSet { UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: "transcriptionEngine") }
    }
    
    // 阶跃 ASR 切片转录周期 (10秒 / 20秒 / 30秒 / 课后)
    @Published public var stepfunChunkInterval: StepfunChunkInterval {
        didSet { UserDefaults.standard.set(stepfunChunkInterval.rawValue, forKey: "stepfunChunkInterval") }
    }
    @Published public var isChunkTranscribing: Bool = false"""
        text = text.replace(target_prop, new_prop)

        # In init()
        target_init = """        let savedEngine = UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "apple"
        self.transcriptionEngine = TranscriptionEngine(rawValue: savedEngine) ?? .apple"""
        new_init = """        let savedEngine = UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "apple"
        self.transcriptionEngine = TranscriptionEngine(rawValue: savedEngine) ?? .apple
        let savedIntervalVal = UserDefaults.standard.integer(forKey: "stepfunChunkInterval")
        self.stepfunChunkInterval = (savedIntervalVal == 0 && !UserDefaults.standard.bool(forKey: "stepfunChunkInterval_set")) ? .twentySeconds : (StepfunChunkInterval(rawValue: savedIntervalVal) ?? .twentySeconds)"""
        text = text.replace(target_init, new_init)

    # 4. Add lastChunkTime and chunkIndex state
    if 'private var lastChunkTime: TimeInterval = 0' not in text:
        target_vars = "    private var speechTask: SFSpeechRecognitionTask?\n"
        new_vars = "    private var speechTask: SFSpeechRecognitionTask?\n    private var lastChunkTime: TimeInterval = 0\n"
        text = text.replace(target_vars, new_vars)

    # 5. In startRecording, reset lastChunkTime
    if 'self.lastChunkTime = 0' not in text:
        target_rec_reset = "            self.recordingElapsed = 0\n"
        new_rec_reset = "            self.recordingElapsed = 0\n            self.lastChunkTime = 0\n"
        text = text.replace(target_rec_reset, new_rec_reset)

    # 6. Update timer block for chunk ASR
    old_timer = """            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, self.isRecording, !self.isPaused else { return }
                    if let cap = self.capture {
                        self.recordingElapsed = cap.recordedDuration
                        self.currentSession?.duration = self.recordingElapsed
                    }
                }
            }"""

    new_timer = """            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, self.isRecording, !self.isPaused else { return }
                    if let cap = self.capture {
                        self.recordingElapsed = cap.recordedDuration
                        self.currentSession?.duration = self.recordingElapsed
                    }
                    
                    // 阶跃 ASR 周期切片实时转录 (10秒 / 20秒 / 30秒)
                    if self.transcriptionEngine == .stepfun && self.stepfunChunkInterval.rawValue > 0 {
                        let interval = Double(self.stepfunChunkInterval.rawValue)
                        if self.recordingElapsed - self.lastChunkTime >= interval {
                            let chunkStart = self.lastChunkTime
                            let chunkEnd = self.recordingElapsed
                            self.lastChunkTime = self.recordingElapsed
                            
                            if let wavData = self.capture?.takeCurrentSliceWavData(), wavData.count > 44 + 8000 {
                                let curSessionId = self.currentSession?.id
                                self.isChunkTranscribing = true
                                Task {
                                    do {
                                        let transcribed = try await self.callStepFunASR(audioData: wavData)
                                        let clean = transcribed.trimmingCharacters(in: .whitespacesAndNewlines)
                                        DispatchQueue.main.async {
                                            self.isChunkTranscribing = false
                                            if !clean.isEmpty, let targetId = curSessionId {
                                                let seg = TranscriptSegment(startTime: chunkStart, endTime: chunkEnd, text: clean)
                                                if self.currentSession?.id == targetId {
                                                    self.currentSession?.segments.append(seg)
                                                }
                                                if let idx = self.sessions.firstIndex(where: { $0.id == targetId }) {
                                                    self.sessions[idx].segments.append(seg)
                                                }
                                                self.saveSessions()
                                            }
                                        }
                                    } catch {
                                        DispatchQueue.main.async {
                                            self.isChunkTranscribing = false
                                        }
                                        print("StepFun chunk ASR error:", error)
                                    }
                                }
                            }
                        }
                    }
                }
            }"""

    if old_timer in text:
        text = text.replace(old_timer, new_timer)
        print(f"Updated recordingTimer in {file_path}")

    # 7. Update stopRecording for remaining chunk
    stop_marker = """        if transcriptionEngine == .stepfun && !stepfunApiKey.isEmpty {"""
    new_stop_block = """        // 阶跃 ASR 切片模式：上传最后残留的音频切片
        if transcriptionEngine == .stepfun && stepfunChunkInterval.rawValue > 0 && !stepfunApiKey.isEmpty {
            if let remainingWav = self.capture?.takeCurrentSliceWavData(), remainingWav.count > 44 + 8000 {
                let chunkStart = self.lastChunkTime
                let chunkEnd = self.recordingElapsed
                let targetId = cur.id
                Task {
                    do {
                        let transcribed = try await self.callStepFunASR(audioData: remainingWav)
                        let clean = transcribed.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty {
                            DispatchQueue.main.async {
                                if let idx = self.sessions.firstIndex(where: { $0.id == targetId }) {
                                    let seg = TranscriptSegment(startTime: chunkStart, endTime: chunkEnd, text: clean)
                                    self.sessions[idx].segments.append(seg)
                                    self.saveSessions()
                                }
                            }
                        }
                    } catch {
                        print("Final chunk ASR error:", error)
                    }
                }
            }
            // 实时切片已完成转写，直接清理本地音频
            try? FileManager.default.removeItem(at: fileURL)
        } else if transcriptionEngine == .stepfun && !stepfunApiKey.isEmpty {"""

    if stop_marker in text and '上传最后残留的音频切片' not in text:
        text = text.replace(stop_marker, new_stop_block)
        print(f"Updated stopRecording in {file_path}")

    # 8. Update callStepFunASR to support audioData and audio.wav
    old_call_asr = """    public func callStepFunASR(audioURL: URL) async throws -> String {
        let cleanBase = stepfunBaseURL.hasSuffix("/") ? String(stepfunBaseURL.dropLast()) : stepfunBaseURL
        guard let url = URL(string: "\\(cleanBase)/audio/transcriptions") else { throw URLError(.badURL) }
        
        let boundary = "Boundary-\\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \\(stepfunApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        
        let audioData = try Data(contentsOf: audioURL)
        var body = Data()
        
        body.append("--\\(boundary)\\r\\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\\"model\\"\\r\\n\\r\\n".data(using: .utf8)!)
        body.append("\\(stepfunAsrModel)\\r\\n".data(using: .utf8)!)
        
        body.append("--\\(boundary)\\r\\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\\"file\\"; filename=\\"audio.caf\\"\\r\\n".data(using: .utf8)!)
        body.append("Content-Type: audio/x-caf\\r\\n\\r\\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\\r\\n--\\(boundary)--\\r\\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        if !(200...299).contains(http.statusCode) {
            let errStr = String(data: data, encoding: .utf8) ?? "HTTP \\(http.statusCode)"
            throw NSError(domain: "StepFunASR", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errStr])
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text
        }
        return ""
    }"""

    new_call_asr = """    public func callStepFunASR(audioURL: URL) async throws -> String {
        let audioData = try Data(contentsOf: audioURL)
        return try await callStepFunASR(audioData: audioData)
    }

    public func callStepFunASR(audioData: Data) async throws -> String {
        let cleanBase = stepfunBaseURL.hasSuffix("/") ? String(stepfunBaseURL.dropLast()) : stepfunBaseURL
        guard let url = URL(string: "\\(cleanBase)/audio/transcriptions") else { throw URLError(.badURL) }
        
        let boundary = "Boundary-\\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \\(stepfunApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        
        var body = Data()
        body.append("--\\(boundary)\\r\\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\\"model\\"\\r\\n\\r\\n".data(using: .utf8)!)
        body.append("\\(stepfunAsrModel)\\r\\n".data(using: .utf8)!)
        
        body.append("--\\(boundary)\\r\\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\\"file\\"; filename=\\"audio.wav\\"\\r\\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\\r\\n\\r\\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\\r\\n--\\(boundary)--\\r\\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        if !(200...299).contains(http.statusCode) {
            let errStr = String(data: data, encoding: .utf8) ?? "HTTP \\(http.statusCode)"
            // 如果遇到静音或无语音，阶跃返回 no speech found，优雅返回空字符串
            if errStr.contains("no speech found") {
                return ""
            }
            throw NSError(domain: "StepFunASR", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errStr])
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text
        }
        return ""
    }"""

    if old_call_asr in text:
        text = text.replace(old_call_asr, new_call_asr)
        print(f"Updated callStepFunASR in {file_path}")

    with open(file_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    print(f"Finished ClassroomManager updates for {file_path}")
