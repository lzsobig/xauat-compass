import Foundation

/// Uses the same quantized Silero model as Listen; never contacts a remote service.
final class SileroVoiceDetector {
    #if CLASSROOM_SHERPA
    private let detector: OpaquePointer

    init?(modelURL: URL? = Bundle.main.url(forResource: "silero_vad.int8", withExtension: "onnx"), threshold: Float = 0.35) {
        guard let modelURL, FileManager.default.fileExists(atPath: modelURL.path) else { return nil }
        let pointer = modelURL.path.withCString { modelPath in
            "cpu".withCString { provider in
                var config = SherpaOnnxVadModelConfig()
                config.silero_vad.model = modelPath
                config.silero_vad.threshold = min(0.9, max(0.1, threshold))
                // The slice buffer owns the endpoint wait.
                config.silero_vad.min_silence_duration = 0.032
                config.silero_vad.min_speech_duration = 0.032
                config.silero_vad.window_size = 512
                config.silero_vad.max_speech_duration = 60
                config.sample_rate = 16000
                config.num_threads = 1
                config.provider = provider
                return SherpaOnnxCreateVoiceActivityDetector(&config, 30)
            }
        }
        guard let pointer else { return nil }
        detector = pointer
    }

    func isSpeech(_ window: [Float]) -> Bool {
        window.withUnsafeBufferPointer { buffer in
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(detector, buffer.baseAddress, Int32(buffer.count))
        }
        let speech = SherpaOnnxVoiceActivityDetectorDetected(detector) != 0
        while SherpaOnnxVoiceActivityDetectorEmpty(detector) == 0 {
            SherpaOnnxVoiceActivityDetectorPop(detector)
        }
        return speech
    }

    deinit { SherpaOnnxDestroyVoiceActivityDetector(detector) }
    #else
    init?(modelURL: URL? = nil, threshold: Float = 0.35) { return nil }
    func isSpeech(_ window: [Float]) -> Bool { false }
    #endif
}
