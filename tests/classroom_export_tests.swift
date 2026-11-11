import Foundation
import CoreGraphics
import ImageIO

@main
struct ClassroomExportTests {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let pixels = Data(repeating: 180, count: 120 * 80 * 3)
        let provider = CGDataProvider(data: pixels as CFData)!
        let image = CGImage(width: 120, height: 80, bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: 360, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let jpeg = CFDataCreateMutable(nil, 0)!
        let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        let slideURL = output.appendingPathComponent("fixture.jpg")
        try (jpeg as Data).write(to: slideURL)
        let first = TranscriptSegment(sequenceIndex: 0, startTime: 0, endTime: 18, text: "第一段，受力分析 & <公式>")
        let second = TranscriptSegment(sequenceIndex: 1, startTime: 18, endTime: 36, text: "第二段，老师布置作业")
        var lesson = LessonSession(title: "中文课堂：图文导出测试", duration: 45, status: .completed,
            segments: [first, second],
            notes: [LessonNote(style: .minutes, content: "## 课堂内容\n结构受力分析\n\n| 项目 | 内容 |\n|---|---|\n| 重点 | 计算公式 |\n\n## 作业与提醒\n完成第二题 [00:18]")],
            qaPairs: [QAPair(question: "怎么理解这张图？", answer: "结合实录分析 [00:18]", citationSeconds: 18, imageJPEG: jpeg as Data)])
        lesson.attachments = [LessonAttachment(time: 12, segmentId: first.id, fileName: "fixture.jpg"),
                              LessonAttachment(time: 40, segmentId: nil, fileName: "fixture.jpg")]
        func generate(_ format: ClassroomExportFormat, _ images: Bool, _ name: String,
                      sections: Set<ClassroomExportSection> = Set(ClassroomExportSection.allCases)) throws {
            let options = ClassroomExportOptions(sections: sections, format: format, includeImages: images)
            let url = try ClassroomExporter.export(session: lesson, options: options) { _ in slideURL }
            try FileManager.default.copyItem(at: url, to: output.appendingPathComponent(name))
        }
        try generate(.txt, false, "sample.txt")
        try generate(.markdown, false, "sample.md")
        try generate(.markdown, true, "sample-markdown.zip")
        try generate(.word, true, "sample-word.docx")
        try generate(.word, false, "sample-word-text.docx")
        try generate(.word, true, "minutes-only.docx", sections: [.minutes])
        try generate(.markdown, true, "minutes-only.zip", sections: [.minutes])
        lesson.notes.append(LessonNote(style: .detailedOutline, content: "原有详细笔记需要保留并单独导出"))
        let selectedNote = ClassroomExportOptions(sections: [.minutes], format: .txt, includeImages: false, noteStyle: .detailedOutline)
        let selectedBlocks = try ClassroomExporter.blocks(session: lesson, options: selectedNote) { _ in slideURL }
        let selectedText = ClassroomExporter.markdown(selectedBlocks, images: false, headings: false)
        precondition(selectedText.contains("原有详细笔记需要保留并单独导出"))
        precondition(!selectedText.contains("结构受力分析"), "single-note TXT must not accidentally include another style")
        precondition(selectedText.contains("课件图 [00:12]"), "single-item exports must retain photo positions")
        let options = ClassroomExportOptions(sections: [.transcript], format: .word, includeImages: true)
        do {
            _ = try ClassroomExporter.export(session: lesson, options: options) { _ in output.appendingPathComponent("missing.jpg") }
            preconditionFailure("missing photos must not silently disappear")
        } catch ClassroomExportFailure.missingImage { }
        let invalid = output.appendingPathComponent("invalid.jpg")
        try Data("not an image".utf8).write(to: invalid)
        do {
            _ = try ClassroomExporter.export(session: lesson, options: options) { _ in invalid }
            preconditionFailure("corrupt photos must report a failure")
        } catch ClassroomExportFailure.corruptImage { }
        let txt = try String(contentsOf: output.appendingPathComponent("sample.txt"), encoding: .utf8)
        precondition(txt.range(of: "第一段")!.lowerBound < txt.range(of: "课件图 [00:12]")!.lowerBound)
        precondition(txt.range(of: "课件图 [00:12]")!.lowerBound < txt.range(of: "第二段")!.lowerBound)
        print("Production export fixture generation passed")
    }
}
