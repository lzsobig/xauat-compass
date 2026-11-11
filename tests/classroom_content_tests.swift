import Foundation

@main
struct ClassroomContentTests {
    static func main() throws {
        for provider in CloudTranscriptionProvider.allCases {
            let key = provider == .siliconFlow ? "test-silicon-key" : "test-step-key"
            let request = try ClassroomASRRequest.make(provider: provider, key: key, audioData: Data([1, 2, 3]))
            precondition(request.url?.absoluteString == provider.endpoint)
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + key)
            let body = String(decoding: request.httpBody!, as: UTF8.self)
            precondition(body.contains(provider.model))
            let other: CloudTranscriptionProvider = provider == .siliconFlow ? .stepFun : .siliconFlow
            precondition(!body.contains(other.model), "the selected provider must determine the request model")
        }
        do {
            _ = try ClassroomASRRequest.make(provider: .stepFun, key: "  ", audioData: Data())
            preconditionFailure("missing key must never fall back to another provider")
        } catch { }
        // Exercise production slicing with deterministic VAD decisions, including exact audio ownership.
        var slicer = ClassroomSliceBuffer()
        let original = (0..<700123).map { Int16($0 % 30000) }
        var slices: [ClassroomAudioSlice] = []
        for offset in stride(from: 0, to: original.count, by: 512) {
            slicer.append(Array(original[offset..<min(original.count, offset + 512)])) { _ in true }
            if let slice = slicer.take() { slices.append(slice) }
        }
        if let tail = slicer.take(final: true) { slices.append(tail) }
        precondition(slices.count >= 3)
        for (index, slice) in slices.enumerated() {
            precondition(slice.samples == Array(original[slice.startSample..<slice.endSample]))
            precondition(slice.samples.count <= 320000)
            if index > 0 { precondition(slice.startSample == slices[index - 1].endSample - 16000) }
        }
        precondition(slices.last?.endSample == original.count, "the last short tail must not be lost")
        precondition(slicer.take(final: true) == nil, "a second stop must not submit duplicate audio")
        var delayed = ClassroomSliceBuffer()
        let delayedCount = 62 * 16000 + 17
        delayed.append(Array(repeating: 3000, count: delayedCount)) { _ in true }
        var flushedEnd = 0
        var flushCount = 0
        while let slice = delayed.take(final: true) {
            precondition(slice.samples.count <= 320000)
            precondition(slice.endSample > flushedEnd)
            if flushCount > 0 { precondition(slice.startSample == flushedEnd - 16000) }
            flushedEnd = slice.endSample
            flushCount += 1
        }
        precondition(flushedEnd == delayedCount && flushCount >= 4, "delayed UI timers must not create a huge final upload or lose the tail")
        var shortWord = ClassroomSliceBuffer()
        shortWord.append(Array(repeating: 1200, count: 512)) { _ in true }
        precondition(shortWord.hasDetectedSpeech, "pending speech must be visible even before a chunk is sealed")
        shortWord.append(Array(repeating: 0, count: 17920)) { _ in false }
        let natural = shortWord.take()!
        precondition(!shortWord.hasDetectedSpeech)
        precondition(natural.endSample == 512 + 8000, "preserve short words and the post-roll")
        var missingModel = ClassroomSliceBuffer()
        missingModel.append(Array(repeating: 8000, count: 512)) { _ in nil }
        missingModel.append(Array(repeating: 0, count: 17920)) { _ in nil }
        precondition(missingModel.take() != nil, "RMS fallback must remain usable")
        let boundary = TranscriptSegment(startTime: 110, endTime: 125, text: "边界以前的旧内容")
        let recent = TranscriptSegment(startTime: 130, endTime: 145, text: "最近的老师提问")
        let future = TranscriptSegment(startTime: 295, endTime: 310, text: "尚未完成的一句")
        precondition(ClassroomQuestionContext.recent([boundary, recent, future], end: 300).map { $0.id } == [recent.id])
        let lecture = (0..<150).map { index in
            TranscriptSegment(sequenceIndex: index, startTime: Double(index * 20), endTime: Double(index * 20 + 20),
                text: index == 70 ? "本节讲解桁架零杆的判断方法" : String(repeating: "其他课堂内容", count: 50))
        }
        let retrieval = ClassroomQuestionContext.retrieve(lecture, query: "怎么判断桁架中的零杆", budget: 900)
        precondition(retrieval.contains(where: { $0.sequenceIndex == 70 }), "Chinese keyword retrieval must find the actual topic")
        precondition(retrieval.reduce(0) { $0 + $1.text.count } <= 900)
        precondition(retrieval.count < 10, "neighbor expansion must not cascade through the lecture")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var lesson = LessonSession(title: "中文测试课", status: .completed)
        let encoded = try encoder.encode(lesson)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for key in ["attachments", "automaticMinutesAttempted", "minutesGenerationError"] {
            legacy.removeValue(forKey: key)
        }
        let restored = try decoder.decode(LessonSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(restored.attachments.isEmpty && !restored.automaticMinutesAttempted)

        precondition(stitchTranscripts(previous: "计算结果", current: "结果如下") == "结果如下", "two characters are real speech")
        precondition(stitchTranscripts(previous: "今天讨论受力分析", current: "受力分析，然后计算") == "然后计算")
        precondition(stitchTranscripts(previous: "前句", current: "。") == "。")
        lesson.chunkTasks = [
            ChunkTranscriptionTask(sequenceIndex: 0, startTime: 0, endTime: 18, chunkFileName: "0.wav"),
            ChunkTranscriptionTask(sequenceIndex: 1, startTime: 17.2, endTime: 35, chunkFileName: "1.wav"),
            ChunkTranscriptionTask(sequenceIndex: 2, startTime: 35, endTime: 38, chunkFileName: "2.wav")
        ]
        lesson.marks = [5]
        // Simulate a failed first chunk, followed by retry after its successor finished.
        lesson.completeTranscriptChunk(at: 1, text: "受力分析，然后计算")
        let successorID = lesson.segments[0].id
        lesson.segments[0].isMarked = true
        lesson.completeTranscriptChunk(at: 0, text: "今天讨论受力分析")
        precondition(lesson.segments[0].isMarked, "a mark made before ASR finished must survive")
        precondition(lesson.segments[1].text == "然后计算")
        precondition(lesson.segments[1].id == successorID && lesson.segments[1].isMarked)
        precondition(lesson.chunkTasks[1].rawRecognizedText == "受力分析，然后计算")
        lesson.completeTranscriptChunk(at: 2, text: "然后计算这里还要重复")
        precondition(lesson.segments[2].text == "然后计算这里还要重复", "nonoverlapping speech must never deduplicate")

        var attachment = LessonAttachment(time: 20, segmentId: successorID, fileName: "slide.jpg")
        precondition(attachment.resolvedSegment(in: lesson.segments) == successorID)
        let replacement = TranscriptSegment(sequenceIndex: 1, startTime: 18, endTime: 35, text: "重新转写")
        precondition(attachment.resolvedSegment(in: [replacement]) == replacement.id)
        attachment.time = 50
        precondition(attachment.resolvedSegment(in: [replacement]) == nil, "silent timestamps stay unattached")
        lesson.attachments = [attachment]
        lesson.automaticMinutesAttempted = true
        let roundtrip = try decoder.decode(LessonSession.self, from: encoder.encode(lesson))
        precondition(roundtrip.attachments[0].id == attachment.id && roundtrip.automaticMinutesAttempted)
        var interrupted = lesson
        interrupted.minutesGenerationState = .generating
        precondition(interrupted.recoverInterruptedMinutes())
        precondition(interrupted.minutesGenerationState == .queued && !interrupted.automaticMinutesAttempted)
        let manualNote = LessonNote(style: .minutes, content: "手工整理的纪要")
        interrupted.notes = [manualNote]
        interrupted.minutesGenerationState = .generating
        precondition(interrupted.recoverInterruptedMinutes())
        precondition(interrupted.notes[0].content == manualNote.content && interrupted.notes[0].id == manualNote.id)
        precondition(interrupted.minutesGenerationState == .failed)
        var offlineRecovery = lesson
        offlineRecovery.mode = .recordOnly
        offlineRecovery.status = .pendingCatchUp
        offlineRecovery.notes = []
        offlineRecovery.automaticMinutesAttempted = false
        offlineRecovery.minutesGenerationState = nil
        precondition(offlineRecovery.recoverCompletedTranscription())
        precondition(offlineRecovery.status == .completed && offlineRecovery.minutesGenerationState == .queued)
        precondition(!offlineRecovery.recoverCompletedTranscription(), "recovery must not schedule duplicate jobs")

        for text in ["", "短句", String(repeating: "课堂中文内容。", count: 7000), String(repeating: "段落内容\n", count: 5000)] {
            let batches = ClassroomTextBatches.split(text, limit: 8000)
            precondition(batches.joined() == text, "batching must not lose a character")
            precondition(batches.allSatisfy { !$0.isEmpty && $0.count <= 8000 })
        }
        print("Production classroom content checks passed")
    }
}
