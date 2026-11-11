import Foundation

struct ClassroomSegmentationConfig {
    // Listen's classroom preset; short tail audio is retained rather than rejected by duration.
    var endSilenceSamples = 17600  // 1.1 s
    var preRollSamples = 32000     // 2 s
    var postRollSamples = 8000     // 0.5 s
    var maximumSamples = 320000    // 20 s, wait for pauses before this hard limit
    var overlapSamples = 16000     // 1 s
}

struct ClassroomAudioSlice {
    var samples: [Int16]
    var startSample: Int
    var endSample: Int
}

/// Audio sample ownership is independent of the network queue and ASR results.
struct ClassroomSliceBuffer {
    var configuration = ClassroomSegmentationConfig()
    private(set) var samples: [Int16] = []
    private var pendingDetection: [Int16] = []
    private var totalSamples = 0
    private var classifiedUntil = 0
    private var bufferStart = 0
    private var lastSpeechEnd = 0
    private var speechSinceCut = false
    private var lastOutputEnd = 0
    private var retainedOverlap = 0
    private var noiseFloor: Float = 0.003
    var hasDetectedSpeech: Bool { speechSinceCut }

    mutating func append(_ input: [Int16], voiceDetection: ([Float]) -> Bool?) {
        samples.append(contentsOf: input)
        pendingDetection.append(contentsOf: input)
        totalSamples += input.count
        var offset = 0
        while pendingDetection.count - offset >= 512 {
            let window = pendingDetection[offset..<(offset + 512)].map { Float($0) / 32768 }
            let rms = sqrt(window.reduce(Float(0)) { $0 + $1 * $1 } / 512)
            let threshold = max(0.006, min(0.04, noiseFloor * 2.8))
            let speech = voiceDetection(window) ?? (rms >= threshold)
            classifiedUntil += 512
            if speech {
                speechSinceCut = true
                lastSpeechEnd = classifiedUntil
            } else {
                if rms < threshold { noiseFloor = noiseFloor * 0.98 + rms * 0.02 }
            }
            offset += 512
        }
        if offset > 0 { pendingDetection.removeFirst(offset) }
        // Keep a pre-roll for a quiet onset, never discard an already detected short word.
        if !speechSinceCut && retainedOverlap == 0 && samples.count > configuration.preRollSamples {
            let count = samples.count - configuration.preRollSamples
            samples.removeFirst(count)
            bufferStart += count
        }
    }

    mutating func take(final: Bool = false) -> ClassroomAudioSlice? {
        let hasNewAudio = totalSamples > lastOutputEnd && !samples.isEmpty
        let naturalBreak = speechSinceCut && classifiedUntil - lastSpeechEnd >= configuration.endSilenceSamples
        let forcedBreak = samples.count >= configuration.maximumSamples && speechSinceCut
        guard (final && hasNewAudio) || naturalBreak || forcedBreak else { return nil }
        let end: Int
        let terminal = final && samples.count <= configuration.maximumSamples
        if terminal { end = totalSamples }
        else if final { end = min(totalSamples, bufferStart + configuration.maximumSamples) }
        else if naturalBreak { end = min(totalSamples, lastSpeechEnd + configuration.postRollSamples) }
        else { end = min(totalSamples, bufferStart + configuration.maximumSamples) }
        let count = max(0, min(samples.count, end - bufferStart))
        guard count > 0 else { return nil }
        let output = ClassroomAudioSlice(samples: Array(samples.prefix(count)), startSample: bufferStart, endSample: end)
        let hardBoundary = !terminal && (final || (forcedBreak && !naturalBreak))
        retainedOverlap = hardBoundary ? min(configuration.overlapSamples, count) : 0
        let removeCount = count - retainedOverlap
        samples.removeFirst(removeCount)
        bufferStart += removeCount
        lastOutputEnd = end
        // Preserve speech already classified beyond a hard boundary; overlap alone cannot start a segment.
        speechSinceCut = !terminal && lastSpeechEnd > end
        return output
    }
}
