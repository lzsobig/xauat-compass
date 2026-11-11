import AVFoundation
import Foundation

@main
struct Replay {
    struct Clip: Codable {
        let name: String
        let start: Double
        let end: Double
    }

    static func main() throws {
        let input = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let scratch = output.deletingLastPathComponent()
        let format = input.processingFormat
        let originalA = try AVAudioFile(forWriting: scratch.appendingPathComponent("old.caf"), settings: format.settings)
        let originalB = try AVAudioFile(forWriting: scratch.appendingPathComponent("new.caf"), settings: format.settings)
        let old = OldCapture(file: originalA, sampleRate: format.sampleRate, collectSlices: true)
        let new = NewCapture(file: originalB, sampleRate: format.sampleRate, collectSlices: true)
        precondition(SileroVoiceDetector() != nil, "The app detector must load in replay")
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var runs = ["build22": [Clip](), "build24": [Clip]()]
        func store(_ clip: (data: Data, start: Double, end: Double)?, _ name: String) throws {
            guard let clip else { return }
            let filename = "\(name)-\(runs[name]!.count + 1).wav"
            try clip.data.write(to: output.appendingPathComponent(filename))
            runs[name]!.append(Clip(name: filename, start: clip.start, end: clip.end))
        }
        var frames: Int64 = 0
        var nextCheck = format.sampleRate / 2
        while input.framePosition < input.length {
            try input.read(into: buffer)
            precondition(buffer.frameLength > 0)
            if let error = old.append(buffer) { throw error }
            if let error = new.append(buffer) { throw error }
            frames += Int64(buffer.frameLength)
            if Double(frames) >= nextCheck {
                try store(old.takeSlice(), "build22")
                try store(new.takeSlice(), "build24")
                nextCheck += format.sampleRate / 2
            }
        }
        try store(old.takeSlice(final: true), "build22")
        while let clip = new.takeSlice(final: true) { try store(clip, "build24") }
        precondition(abs(old.recordedDuration - new.recordedDuration) < 0.001)
        precondition(abs(runs["build24"]!.last!.end - new.recordedDuration) < 0.001)
        try JSONEncoder().encode(runs).write(to: output.appendingPathComponent("clips.json"))
        print("Replayed \(new.recordedDuration) seconds through original capture classes. Clip counts \(runs.mapValues { $0.count })")
    }
}
