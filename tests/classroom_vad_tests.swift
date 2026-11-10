import AVFoundation
import Foundation

@main
struct ClassroomVADTests {
    static func main() throws {
        #if CLASSROOM_SHERPA
        let model = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let detector = SileroVoiceDetector(modelURL: model) else {
            preconditionFailure("The real bundled Silero model must initialize")
        }
        precondition(SileroVoiceDetector(modelURL: URL(fileURLWithPath: "/missing-silero.onnx")) == nil)
        var silenceDetections = 0
        for _ in 0..<100 {
            if detector.isSpeech(Array(repeating: 0, count: 512)) { silenceDetections += 1 }
        }
        precondition(silenceDetections == 0)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[2]))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let channel = buffer.floatChannelData![0]
        let step = file.processingFormat.sampleRate / 16000
        var speech: [Float] = []
        var position: Double = 0
        while position < Double(buffer.frameLength) {
            speech.append(channel[Int(position)])
            position += step
        }
        var detected = 0
        for offset in stride(from: 0, to: max(0, speech.count - 511), by: 512) {
            if detector.isSpeech(Array(speech[offset..<(offset + 512)])) { detected += 1 }
        }
        precondition(detected > 5, "real synthetic speech must be recognized as speech")
        print("Real Silero model initialized, silence frames=\(silenceDetections), speech frames=\(detected)")
        let quietDetector = SileroVoiceDetector(modelURL: model)!
        var quietDetections = 0
        for offset in stride(from: 0, to: max(0, speech.count - 511), by: 512) {
            let quiet = speech[offset..<(offset + 512)].map { $0 * 0.12 }
            if quietDetector.isSpeech(quiet) { quietDetections += 1 }
        }
        precondition(quietDetections > 5, "quiet speech must still activate the neural detector")
        let noiseDetector = SileroVoiceDetector(modelURL: model)!
        var seed: UInt32 = 42
        var noiseDetections = 0
        for _ in 0..<300 {
            let noise = (0..<512).map { _ -> Float in
                seed = seed &* 1664525 &+ 1013904223
                return (Float(seed & 65535) / 32768 - 1) * 0.015
            }
            if noiseDetector.isSpeech(noise) { noiseDetections += 1 }
        }
        precondition(noiseDetections < 30, "stationary background noise must not be continuously classified as speech")
        let stressDetector = SileroVoiceDetector(modelURL: model)!
        var slicer = ClassroomSliceBuffer()
        let totalSamples = 45 * 60 * 16000
        var sliceCount = 0
        var lastEnd = 0
        let started = Date()
        for position in stride(from: 0, to: totalSamples, by: 512) {
            let count = min(512, totalSamples - position)
            let pcm = (0..<count).map { index -> Int16 in
                let value = max(-1, min(1, speech[(position + index) % speech.count]))
                return Int16(value * 32767)
            }
            slicer.append(pcm) { stressDetector.isSpeech($0) }
            if let slice = slicer.take() {
                precondition(slice.endSample > lastEnd && slice.samples.count <= 320000)
                sliceCount += 1
                lastEnd = slice.endSample
            }
            precondition(slicer.samples.count <= 320512, "the live sample buffer must remain bounded")
        }
        if let tail = slicer.take(final: true) {
            precondition(tail.endSample == totalSamples)
            sliceCount += 1
            lastEnd = tail.endSample
        }
        precondition(lastEnd == totalSamples && sliceCount > 100)
        print("45-minute synthetic-audio stress passed: slices=\(sliceCount), quiet=\(quietDetections), noise=\(noiseDetections), execution_seconds=\(Date().timeIntervalSince(started))")
        #else
        preconditionFailure("This test must link the real sherpa-onnx library")
        #endif
    }
}
