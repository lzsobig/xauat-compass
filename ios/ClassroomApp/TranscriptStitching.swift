import Foundation

// MARK: - 语音切片文字平滑拼接与去重
public func stitchTranscripts(previous: String, current: String) -> String {
    let punctChars = "，。！？、；： \t\n"
    var pCore = previous.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = pCore.last, punctChars.contains(last) {
        pCore.removeLast()
    }
    var cCore = current.trimmingCharacters(in: .whitespacesAndNewlines)
    while let first = cCore.first, punctChars.contains(first) {
        cCore.removeFirst()
    }
    
    guard !pCore.isEmpty else { return current }
    guard !cCore.isEmpty else { return current }
    
    let pChars = Array(pCore)
    let cChars = Array(cCore)
    
    // Require four matching characters before removing an overlap.
    let maxMatchLen = min(14, min(pChars.count, cChars.count))
    if maxMatchLen >= 4 {
        for len in stride(from: maxMatchLen, through: 4, by: -1) {
            let tail = String(pChars.suffix(len))
            let head = String(cChars.prefix(len))
            
            if tail == head {
                if let range = current.range(of: head) {
                    var remaining = String(current[range.upperBound...])
                    while let first = remaining.first, punctChars.contains(first) {
                        remaining.removeFirst()
                    }
                    return remaining
                }
            }
        }
    }
    return current
}

extension LessonSession {
    mutating func completeTranscriptChunk(at taskIndex: Int, text: String) {
        self.chunkTasks[taskIndex].status = .completed
        self.chunkTasks[taskIndex].rawRecognizedText = text
        self.chunkTasks[taskIndex].lastError = nil
        let sequence = self.chunkTasks[taskIndex].sequenceIndex

        // A retried chunk changes its own boundary and the start of its successor.
        for index in self.chunkTasks.indices where
            self.chunkTasks[index].sequenceIndex == sequence ||
            self.chunkTasks[index].sequenceIndex == sequence + 1 {
            let chunk = self.chunkTasks[index]
            guard let rawText = chunk.rawRecognizedText else { continue }
            let predecessor = self.chunkTasks.first {
                $0.sequenceIndex == chunk.sequenceIndex - 1 &&
                    $0.status == .completed && $0.endTime > chunk.startTime
            }
            let previous = predecessor?.rawRecognizedText ?? predecessor?.recognizedText ?? ""
            let displayText = stitchTranscripts(previous: previous, current: rawText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.chunkTasks[index].recognizedText = displayText

            if let segmentIndex = self.segments.firstIndex(where: { $0.sequenceIndex == chunk.sequenceIndex }) {
                self.segments[segmentIndex].text = displayText
            } else if !displayText.isEmpty {
                self.segments.append(TranscriptSegment(
                    sequenceIndex: chunk.sequenceIndex,
                    startTime: chunk.startTime,
                    endTime: chunk.endTime,
                    text: displayText,
                    isMarked: marks.contains { $0 >= chunk.startTime && $0 <= chunk.endTime }
                ))
            }
        }
        self.segments.sort { $0.sequenceIndex < $1.sequenceIndex }
    }
}
