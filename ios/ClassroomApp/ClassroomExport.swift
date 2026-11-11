import Foundation
import ImageIO

enum ClassroomExportSection: String, CaseIterable, Hashable, Sendable {
    case transcript = "实录", minutes = "纪要", questions = "问答"
}

enum ClassroomExportFormat: String, CaseIterable, Sendable {
    case txt = "TXT", markdown = "Markdown", word = "Word"
}

struct ClassroomExportOptions: Sendable {
    var sections: Set<ClassroomExportSection> = [.minutes]
    var format: ClassroomExportFormat = .word
    var includeImages = true
    var noteStyle: NoteStyle? = nil
}

struct ClassroomExportImage {
    let name: String
    let caption: String
    let jpeg: Data?
}

enum ClassroomExportBlock {
    case heading(String, Int)
    case text(String)
    case image(ClassroomExportImage)
}

enum ClassroomExportFailure: LocalizedError {
    case nothingSelected
    case missingImage(String)
    case corruptImage(String)

    var errorDescription: String? {
        switch self {
        case .nothingSelected: return "请至少选择实录、纪要或问答中的一项"
        case .missingImage(let name): return "课件图缺失或无法读取：\(name)"
        case .corruptImage(let name): return "图片无法解码：\(name)"
        }
    }
}

enum ClassroomExporter {
    static func timestamp(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// Every output format consumes these same ordered blocks.
    static func blocks(session: LessonSession, options: ClassroomExportOptions,
                       attachmentURL: (LessonAttachment) -> URL) throws -> [ClassroomExportBlock] {
        guard !options.sections.isEmpty else { throw ClassroomExportFailure.nothingSelected }
        let loadImages = options.includeImages && options.format != .txt
        var result: [ClassroomExportBlock] = [.heading(session.title, 1), .text("课堂时长：" + timestamp(session.duration))]
        func photo(_ attachment: LessonAttachment) throws -> ClassroomExportBlock {
            let data: Data?
            if loadImages {
                do { data = try Data(contentsOf: attachmentURL(attachment)) }
                catch { throw ClassroomExportFailure.missingImage(attachment.fileName) }
            } else { data = nil }
            return .image(ClassroomExportImage(name: "slide-\(attachment.id.uuidString).jpg",
                caption: "课件图 [\(timestamp(attachment.time))]", jpeg: data))
        }
        let attachments = session.attachments.sorted { $0.time < $1.time }
        if options.sections.contains(.transcript) {
            result.append(.heading("课堂实录", 2))
            let segments = session.segments.sorted { $0.startTime < $1.startTime }
            let unassigned = attachments.filter { $0.resolvedSegment(in: segments) == nil }
            var orphanIndex = 0
            for segment in segments {
                while orphanIndex < unassigned.count && unassigned[orphanIndex].time < segment.startTime {
                    result.append(try photo(unassigned[orphanIndex]))
                    orphanIndex += 1
                }
                result.append(.text("[\(timestamp(segment.startTime))] \(segment.text)"))
                for attachment in attachments where attachment.resolvedSegment(in: segments) == segment.id {
                    result.append(try photo(attachment))
                }
            }
            for attachment in unassigned.dropFirst(orphanIndex) { result.append(try photo(attachment)) }
            if segments.isEmpty { result.append(.text("尚无实录文字")) }
        }
        if options.sections.contains(.minutes) {
            let selectedStyle = options.noteStyle ?? .minutes
            result.append(.heading(options.noteStyle?.title ?? "课堂纪要", 2))
            if let note = session.notes.first(where: { $0.style == selectedStyle }) {
                result.append(.text(note.content))
            } else { result.append(.text("尚未生成纪要")) }
            let previousNotes = options.noteStyle == nil ? session.notes.filter { $0.style != .minutes } : []
            for note in previousNotes {
                result.append(.heading(note.style.title, 3))
                result.append(.text(note.content))
            }
            if !options.sections.contains(.transcript) && !attachments.isEmpty {
                result.append(.heading("课件图", 2))
                for attachment in attachments { result.append(try photo(attachment)) }
            }
        }
        if options.sections.contains(.questions) {
            result.append(.heading("课堂问答", 2))
            for (index, pair) in session.qaPairs.enumerated() {
                result.append(.heading("问题 \(index + 1)", 3))
                result.append(.text(pair.question))
                if let data = pair.imageJPEG {
                    result.append(.image(ClassroomExportImage(name: "question-\(pair.id.uuidString).jpg",
                        caption: "问题 \(index + 1) 附图", jpeg: loadImages ? data : nil)))
                }
                result.append(.text(pair.answer))
                if let time = pair.citationSeconds { result.append(.text("实录定位 [\(timestamp(time))]")) }
            }
            if session.qaPairs.isEmpty { result.append(.text("尚无课堂问答")) }
        }
        return result
    }

    static func export(session: LessonSession, options: ClassroomExportOptions,
                       attachmentURL: (LessonAttachment) -> URL) throws -> URL {
        let content = try blocks(session: session, options: options, attachmentURL: attachmentURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("classroom-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r").union(.controlCharacters)
            let title = String(session.title.components(separatedBy: unsafe).joined(separator: "-").prefix(70))
            let name = title.isEmpty ? "课堂记录" : title
            switch options.format {
            case .txt:
                let output = directory.appendingPathComponent(name + ".txt")
                try markdown(content, images: false, headings: false).write(to: output, atomically: true, encoding: .utf8)
                return output
            case .markdown:
                if !options.includeImages {
                    let output = directory.appendingPathComponent(name + ".md")
                    try markdown(content, images: false).write(to: output, atomically: true, encoding: .utf8)
                    return output
                }
                let output = directory.appendingPathComponent(name + ".zip")
                let archive = try Archive(url: output, accessMode: .create)
                try add(Data(markdown(content, images: true).utf8), path: name + ".md", to: archive)
                for block in content {
                    if case .image(let image) = block, let jpeg = image.jpeg {
                        try validate(image)
                        try add(jpeg, path: "images/" + image.name, to: archive)
                    }
                }
                return output
            case .word:
                let output = directory.appendingPathComponent(name + ".docx")
                try word(content, to: output)
                return output
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func markdown(_ blocks: [ClassroomExportBlock], images: Bool, headings: Bool = true) -> String {
        blocks.map { block in
            switch block {
            case .heading(let text, let level): return headings ? String(repeating: "#", count: level) + " " + text : text
            case .text(let text): return text
            case .image(let image):
                if images && image.jpeg != nil {
                    let caption = image.caption.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                    return "![\(caption)](images/\(image.name))"
                }
                return "[\(image.caption)]"
            }
        }.joined(separator: "\n\n") + "\n"
    }

    private static func validate(_ image: ClassroomExportImage) throws {
        guard let jpeg = image.jpeg,
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw ClassroomExportFailure.corruptImage(image.caption)
        }
    }

    private static func add(_ data: Data, path: String, to archive: Archive) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        }
    }

    private static func xml(_ text: String) -> String {
        let cleaned = String(text.unicodeScalars.filter { scalar in
            scalar.value == 9 || scalar.value == 10 || scalar.value == 13 ||
            (scalar.value >= 32 && scalar.value != 0xfffe && scalar.value != 0xffff)
        })
        return cleaned.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func paragraph(_ text: String, level: Int = 0, keepWithNext: Bool = false) -> String {
        var properties = level > 0 ? "<w:pStyle w:val=\"Heading\(min(level, 3))\"/>" : ""
        if keepWithNext { properties += "<w:keepNext/>" }
        if !properties.isEmpty { properties = "<w:pPr>" + properties + "</w:pPr>" }
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        return "<w:p>\(properties)<w:r><w:t xml:space=\"preserve\">\(xml(plain))</w:t></w:r></w:p>"
    }

    /// Convert the common Markdown structures produced by the classroom model.
    private static func paragraphs(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var output = ""
        var index = 0
        func cells(_ line: String) -> [String] {
            var parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "|")
            if parts.first?.isEmpty == true { parts.removeFirst() }
            if parts.last?.isEmpty == true { parts.removeLast() }
            return parts.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        while index < lines.count {
            let line = lines[index]
            if line.contains("|"), index + 1 < lines.count {
                let separators = cells(lines[index + 1])
                if !separators.isEmpty && separators.allSatisfy({ cell in
                    cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
                }) {
                    var rows = [cells(line)]
                    index += 2
                    while index < lines.count && lines[index].contains("|") {
                        rows.append(cells(lines[index])); index += 1
                    }
                    let columnCount = max(1, rows.map { $0.count }.max() ?? 1)
                    output += "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>"
                    for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] {
                        output += "<w:\(edge) w:val=\"single\" w:sz=\"4\" w:color=\"CCCCCC\"/>"
                    }
                    output += "</w:tblBorders></w:tblPr><w:tblGrid>" + String(repeating: "<w:gridCol w:w=\"\(9000 / columnCount)\"/>", count: columnCount) + "</w:tblGrid>"
                    for row in rows {
                        output += "<w:tr>"
                        for column in 0..<columnCount { output += "<w:tc>" + paragraph(column < row.count ? row[column] : "") + "</w:tc>" }
                        output += "</w:tr>"
                    }
                    output += "</w:tbl>" + paragraph("")
                    continue
                }
            }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if hashes > 0 && hashes <= 6 && line.dropFirst(hashes).first == " " {
                output += paragraph(String(line.dropFirst(hashes + 1)), level: hashes)
            } else { output += paragraph(line) }
            index += 1
        }
        return output
    }

    private static func word(_ blocks: [ClassroomExportBlock], to output: URL) throws {
        let archive = try Archive(url: output, accessMode: .create)
        let relNS = "http://schemas.openxmlformats.org/package/2006/relationships"
        let officeNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let wNS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        var body = ""
        var relationships = "<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"styles\" Type=\"\(officeNS)/styles\" Target=\"styles.xml\"/>"
        var imageIndex = 0
        for block in blocks {
            switch block {
            case .heading(let text, let level): body += paragraph(text, level: level)
            case .text(let text): body += paragraphs(text)
            case .image(let image):
                body += paragraph(image.caption, keepWithNext: image.jpeg != nil)
                guard let jpeg = image.jpeg else { continue }
                try validate(image)
                imageIndex += 1
                let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
                let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1200
                let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 900
                let scale = min(5486400 / max(1, width), 7315200 / max(1, height))
                let cx = Int(width * scale), cy = Int(height * scale)
                let rid = "image\(imageIndex)"
                try add(jpeg, path: "word/media/" + image.name, to: archive)
                relationships += "<Relationship Id=\"\(rid)\" Type=\"\(officeNS)/image\" Target=\"media/\(image.name)\"/>"
                body += """
                <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">
                <wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(imageIndex)" name="\(xml(image.caption))"/>
                <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>
                <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                <pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="\(image.name)"/><pic:cNvPicPr/></pic:nvPicPr>
                <pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
                <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>
                <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>
                </a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
                """
            }
        }
        relationships += "</Relationships>"
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="\(wNS)" xmlns:r="\(officeNS)" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>
        """
        var styles = "<w:styles xmlns:w=\"\(wNS)\"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:eastAsia=\"等线\"/><w:sz w:val=\"22\"/></w:rPr></w:rPrDefault></w:docDefaults>"
        for level in 1...3 {
            styles += "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"120\"/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"\(36 - level * 4)\"/></w:rPr></w:style>"
        }
        styles += "</w:styles>"
        let types = """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpg" ContentType="image/jpeg"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
        """
        let rootRels = "<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"document\" Type=\"\(officeNS)/officeDocument\" Target=\"word/document.xml\"/></Relationships>"
        for (path, xml) in [("[Content_Types].xml", types), ("_rels/.rels", rootRels), ("word/document.xml", document), ("word/styles.xml", styles), ("word/_rels/document.xml.rels", relationships)] {
            try add(Data(xml.utf8), path: path, to: archive)
        }
    }
}
