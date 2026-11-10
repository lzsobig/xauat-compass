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
        #else
        preconditionFailure("This test must link the real sherpa-onnx library")
        #endif
    }
}
