import AVFoundation
import Foundation

enum OfflineAudioSegmenter {
    /// All task metadata is committed together only after the complete audio was read successfully.
    static func prepare(audioURL: URL, sessionChunkDirectory: URL,
                        modelURL: URL? = Bundle.main.url(forResource: "silero_vad.int8", withExtension: "onnx"),
                        fallbackAudioURL: URL? = nil, speechThreshold: Float = 0.35) throws -> [ChunkTranscriptionTask] {
        do {
            return try prepareAttempt(audioURL: audioURL, sessionChunkDirectory: sessionChunkDirectory,
                                      modelURL: modelURL, speechThreshold: speechThreshold)
        } catch {
            // Compression may publish the complete M4A and retire the CAF before this task opens it.
            guard !(error is CancellationError), let fallbackAudioURL, fallbackAudioURL != audioURL,
                  FileManager.default.fileExists(atPath: fallbackAudioURL.path) else { throw error }
            return try prepareAttempt(audioURL: fallbackAudioURL, sessionChunkDirectory: sessionChunkDirectory,
                                      modelURL: modelURL, speechThreshold: speechThreshold)
        }
    }

    private static func prepareAttempt(audioURL: URL, sessionChunkDirectory: URL,
                                       modelURL: URL?, speechThreshold: Float) throws -> [ChunkTranscriptionTask] {
        let attempt = "offline-" + UUID().uuidString
        let directory = sessionChunkDirectory.appendingPathComponent(attempt, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let file = try AVAudioFile(forReading: audioURL)
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: file.processingFormat, to: format),
                  let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192),
                  let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let detector = SileroVoiceDetector(modelURL: modelURL, threshold: speechThreshold)
            var slicer = ClassroomSliceBuffer()
            var tasks: [ChunkTranscriptionTask] = []
            var inputError: Error?
            var emptyPasses = 0

            func save(_ slice: ClassroomAudioSlice) throws {
                let filename = "chunk-\(tasks.count + 1).wav"
                try pcmToWav(samples: slice.samples).write(to: directory.appendingPathComponent(filename), options: .atomic)
                tasks.append(ChunkTranscriptionTask(sequenceIndex: tasks.count + 1,
                    startTime: Double(slice.startSample) / 16000, endTime: Double(slice.endSample) / 16000,
                    chunkFileName: attempt + "/" + filename))
            }

            while true {
                try Task.checkCancellation()
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { count, inputStatus in
                    guard file.framePosition < file.length else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    do {
                        try file.read(into: input, frameCount: min(count, input.frameCapacity))
                        inputStatus.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                        return input.frameLength > 0 ? input : nil
                    } catch {
                        inputError = error
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                }
                if let inputError { throw inputError }
                if let conversionError { throw conversionError }
                if status == .error { throw CocoaError(.fileReadCorruptFile) }
                if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                    let samples = (0..<Int(output.frameLength)).map { index in
                        Int16(max(-1, min(1, channel[index])) * 32767)
                    }
                    slicer.append(samples) { detector?.isSpeech($0) }
                    while let slice = slicer.take() { try save(slice) }
                    emptyPasses = 0
                } else {
                    emptyPasses += 1
                }
                if status == .endOfStream { break }
                guard emptyPasses < 8 else { throw CocoaError(.fileReadCorruptFile) }
            }
            while let slice = slicer.take(final: true) { try save(slice) }
            guard !tasks.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            return tasks
        } catch {
            // This UUID directory belongs only to this failed preparation; the original recording is untouched.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
