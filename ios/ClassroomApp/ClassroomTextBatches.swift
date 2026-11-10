import Foundation

enum ClassroomTextBatches {
    static func split(_ text: String, limit: Int) -> [String] {
        precondition(limit > 0)
        var batches: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex {
                let midpoint = text.index(start, offsetBy: limit / 2)
                if let newline = text[midpoint..<end].lastIndex(of: "\n") {
                    end = text.index(after: newline)
                }
            }
            batches.append(String(text[start..<end]))
            start = end
        }
        return batches
    }
}
