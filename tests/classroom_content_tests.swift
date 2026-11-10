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
        // Simulate a failed first chunk, followed by retry after its successor finished.
        lesson.completeTranscriptChunk(at: 1, text: "受力分析，然后计算")
        let successorID = lesson.segments[0].id
        lesson.segments[0].isMarked = true
        lesson.completeTranscriptChunk(at: 0, text: "今天讨论受力分析")
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

        for text in ["", "短句", String(repeating: "课堂中文内容。", count: 7000), String(repeating: "段落内容\n", count: 5000)] {
            let batches = ClassroomTextBatches.split(text, limit: 8000)
            precondition(batches.joined() == text, "batching must not lose a character")
            precondition(batches.allSatisfy { !$0.isEmpty && $0.count <= 8000 })
        }
        print("Production classroom content checks passed")
    }
}
