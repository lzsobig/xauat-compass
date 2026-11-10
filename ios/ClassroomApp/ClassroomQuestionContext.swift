import Foundation

enum ClassroomQuestionContext {
    static func recent(_ segments: [TranscriptSegment], end: TimeInterval) -> [TranscriptSegment] {
        let cutoff = max(0, end - 180)
        // A boundary-crossing paragraph cannot safely be split into timed words.
        return segments.filter { $0.startTime >= cutoff && $0.endTime <= end }
            .sorted { $0.startTime < $1.startTime }
    }

    static func terms(_ query: String) -> [String] {
        let words = query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        let stop: Set<String> = ["什么", "怎么", "老师", "这个", "那个", "一下", "这节", "我们", "请问"]
        var terms = Set(words.filter { $0.count >= 2 && !stop.contains($0) })
        for word in words where word.unicodeScalars.contains(where: { $0.value >= 0x3400 && $0.value <= 0x9fff }) {
            let characters = Array(word)
            for size in 2...3 where characters.count >= size {
                for offset in 0...(characters.count - size) {
                    let term = String(characters[offset..<(offset + size)])
                    if !stop.contains(term) { terms.insert(term) }
                }
            }
        }
        return terms.sorted { $0.count > $1.count }
    }

    static func retrieve(_ input: [TranscriptSegment], query: String, budget: Int) -> [TranscriptSegment] {
        guard budget > 0 else { return [] }
        let segments = input.sorted { $0.startTime < $1.startTime }
        if segments.reduce(0, { $0 + $1.text.count }) <= budget { return segments }
        let tokens = terms(query)
        let scores = segments.enumerated().compactMap { index, segment -> (Int, Int)? in
            let text = segment.text.lowercased()
            let score = tokens.reduce(0) { $0 + (text.contains($1) ? min(8, $1.count) : 0) }
            return score > 0 ? (index, score + (segment.isMarked ? 1 : 0)) : nil
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        // Only the original hits expand; adjacent context must not recursively select the whole lesson.
        let anchors = Array(scores.prefix(12).map { $0.0 })
        var selected = Set<Int>()
        var used = 0
        for anchor in anchors {
            for index in [anchor, anchor - 1, anchor + 1] where segments.indices.contains(index) && !selected.contains(index) {
                if used + segments[index].text.count <= budget {
                    selected.insert(index)
                    used += segments[index].text.count
                }
            }
        }
        if !selected.isEmpty { return selected.sorted().map { segments[$0] } }
        // One very long ASR paragraph still needs a bounded excerpt around the matching term.
        guard let first = anchors.first else { return [] }
        var segment = segments[first]
        let lower = segment.text.lowercased()
        let hit = tokens.compactMap { lower.range(of: $0) }.first?.lowerBound ?? lower.startIndex
        let offset = lower.distance(from: lower.startIndex, to: hit)
        let characters = Array(segment.text)
        let start = min(max(0, offset - budget / 3), max(0, characters.count - budget))
        segment.text = String(characters[start..<min(characters.count, start + budget)])
        return [segment]
    }
}
