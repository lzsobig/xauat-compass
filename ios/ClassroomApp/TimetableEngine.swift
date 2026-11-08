import Foundation
import PDFKit
#if canImport(Vision)
import Vision
#endif
#if canImport(UIKit)
import UIKit
#endif

public struct TimetableEngine {
    public static let DAYS = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
    
    public static let RADICALS: [Character: Character] = [
        "⻄": "西", "⻩": "黄", "⻔": "门", "⻓": "长", "⻛": "风", "⻜": "飞", "⻢": "马", "⻥": "鱼",
        "⻝": "食", "⻅": "见", "⻉": "贝", "⻋": "车", "⻚": "页", "⻮": "竹", "⻰": "龙", "⻳": "龟",
        "⻆": "角", "⻘": "青", "⻬": "齐", "⻧": "卤", "⻨": "麦", "⻦": "鸟", "⻤": "鬼", "⻣": "骨",
        "⼀": "一", "⼆": "二", "⽇": "日", "⼤": "大", "⼟": "土", "⽊": "木", "⼯": "工", "⽣": "生",
        "˖": "◇", "•": "●"
    ]
    
    public static func normalizeText(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let result = text.precomposedStringWithCompatibilityMapping
        var mapped = String()
        mapped.reserveCapacity(result.count)
        for ch in result {
            if let repl = RADICALS[ch] {
                mapped.append(repl)
            } else {
                mapped.append(ch)
            }
        }
        return mapped
    }
    
    public static func parseWeeks(_ spec: String) throws -> [(weekFrom: Int, weekTo: Int, parity: String)] {
        let clean = spec.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        let parts = clean.components(separatedBy: CharacterSet(charactersIn: ",，")).filter { !$0.isEmpty }
        var ranges: [(weekFrom: Int, weekTo: Int, parity: String)] = []
        
        let pattern = "^(\\d{1,2})(?:~(\\d{1,2}))?(?:\\((单|双)\\))?$"
        let regex = try NSRegularExpression(pattern: pattern)
        
        for part in parts {
            let nsPart = part as NSString
            guard let match = regex.firstMatch(in: part, range: NSRange(location: 0, length: nsPart.length)) else {
                continue
            }
            let start = Int(nsPart.substring(with: match.range(at: 1))) ?? 1
            var end = start
            if match.range(at: 2).location != NSNotFound {
                end = Int(nsPart.substring(with: match.range(at: 2))) ?? start
            }
            var parity = "all"
            if match.range(at: 3).location != NSNotFound {
                let pStr = nsPart.substring(with: match.range(at: 3))
                if pStr == "单" { parity = "odd" }
                else if pStr == "双" { parity = "even" }
            }
            let fromW = min(start, end)
            let toW = max(start, end)
            ranges.append((weekFrom: fromW, weekTo: toW, parity: parity))
        }
        return ranges
    }
    
    public static func parseEntry(day: Int, entry: String, semester: String = "2026-2027-1") -> (name: String, teacher: String, slots: [TimetableSlot])? {
        // 匹配 1-2节/(1~5,7~8)周 格式
        let pattern = "(\\d{1,2})\\s*-\\s*(\\d{1,2})\\s*节\\s*/\\s*\\(([^)]*(?:\\([^)]*\\)[^)]*)*)\\)\\s*周"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        
        let nsEntry = entry as NSString
        let matches = regex.matches(in: entry, range: NSRange(location: 0, length: nsEntry.length))
        guard !matches.isEmpty else { return nil }
        
        var parts: [(start: Int, end: Int, startPeriod: Int, endPeriod: Int, weeksStr: String)] = []
        for m in matches {
            let startP = Int(nsEntry.substring(with: m.range(at: 1))) ?? 1
            let endP = Int(nsEntry.substring(with: m.range(at: 2))) ?? startP
            let weeks = nsEntry.substring(with: m.range(at: 3))
            parts.append((start: m.range.location, end: m.range.location + m.range.length, startPeriod: startP, endPeriod: endP, weeksStr: weeks))
        }
        
        var name = nsEntry.substring(with: NSRange(location: 0, length: parts[0].start))
        name = name.replacingOccurrences(of: "^[●\\s◇]+|[◇\\s]+$", with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "\n", with: "")
        name = name.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "未命名课程" }
        
        var teacher = ""
        var slots: [TimetableSlot] = []
        
        for i in 0..<parts.count {
            let p = parts[i]
            let tailEnd = (i + 1 < parts.count) ? parts[i + 1].start : nsEntry.length
            let tail = nsEntry.substring(with: NSRange(location: p.end, length: tailEnd - p.end))
            var fields = tail.components(separatedBy: "◇").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if fields.count == 1 {
                let bits = fields[0].components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if bits.count >= 2 {
                    fields = [bits.dropLast().joined(), bits.last!]
                }
            }
            let room = fields.count > 0 ? fields[0].replacingOccurrences(of: "\\s+", with: "", options: .regularExpression) : ""
            if fields.count > 1 && teacher.isEmpty {
                teacher = fields.last!.replacingOccurrences(of: "\\s*/\\s*", with: "/", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let fromPeriod = min(p.startPeriod, p.endPeriod)
            let toPeriod = max(p.startPeriod, p.endPeriod)
            
            if let weekRanges = try? parseWeeks(p.weeksStr) {
                for w in weekRanges {
                    let slot = TimetableSlot(
                        courseName: name,
                        teacher: teacher,
                        room: room,
                        day: day,
                        fromPeriod: fromPeriod,
                        toPeriod: toPeriod,
                        weekFrom: w.weekFrom,
                        weekTo: w.weekTo,
                        parity: w.parity,
                        semester: semester
                    )
                    slots.append(slot)
                }
            }
        }
        
        return (name: name, teacher: teacher, slots: slots)
    }

    /// 核心解析入口：解析 PDF 生成草稿模型，不触发任何持久化修改
    public static func parseTimetableDraft(data: Data) throws -> TimetableImportDraft {
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else {
            throw NSError(domain: "TimetableError", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法打开课表 PDF 或文档为空"])
        }
        
        var extractedSemester = "2026-2027-1"
        var extractedStudentName = ""
        var extractedClassName = ""
        var extractedSchoolName = "西安建筑科技大学"
        var allSlots: [TimetableSlot] = []
        var warnings: [String] = []

        // 1. 扫描所有页面的元数据（学期、班级、姓名、学校）
        for pIdx in 0..<doc.pageCount {
            guard let page = doc.page(at: pIdx) else { continue }
            let rawPage = normalizeText(page.string ?? "")
            
            // 提取学期 (如 2026-2027-1 或 2026-2027学年第1学期)
            if let semMatch = rawPage.range(of: "\\(\\d{4}-\\d{4}-\\d\\)", options: .regularExpression) {
                let semRaw = String(rawPage[semMatch])
                extractedSemester = semRaw.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            } else if let semMatch2 = rawPage.range(of: "\\d{4}-\\d{4}-\\d", options: .regularExpression) {
                extractedSemester = String(rawPage[semMatch2])
            }
            
            // 提取学校
            if rawPage.contains("西安建筑科技大学") {
                extractedSchoolName = "西安建筑科技大学"
            }
            
            // 提取班级
            if let classMatch = rawPage.range(of: "班级[：:]\\s*([^\\s]+)", options: .regularExpression) {
                let s = String(rawPage[classMatch])
                extractedClassName = s.replacingOccurrences(of: "班级：", with: "").replacingOccurrences(of: "班级:", with: "").trimmingCharacters(in: .whitespaces)
            }
            
            // 提取姓名
            if let nameMatch = rawPage.range(of: "姓名[：:]\\s*([^\\s]+)", options: .regularExpression) {
                let s = String(rawPage[nameMatch])
                extractedStudentName = s.replacingOccurrences(of: "姓名：", with: "").replacingOccurrences(of: "姓名:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        
        // 2. 逐页解析课程格子
        for pIdx in 0..<doc.pageCount {
            guard let page = doc.page(at: pIdx) else { continue }
            let pageSlots = parsePageSlots(page: page, semester: extractedSemester, warnings: &warnings)
            allSlots.append(contentsOf: pageSlots)
        }
        
        // 3. 校验解析结果：绝对不允许硬编码兜底冒充真实结果
        if allSlots.isEmpty {
            throw NSError(
                domain: "TimetableError",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "未能从该 PDF 中解析出课程节次，请确认文件是否为教务系统导出的课表 PDF，或检查文件是否清晰可读。"]
            )
        }
        
        // 4. 根据识别出的 slots 生成草稿课程项 (DraftCourseItem)
        var courseMap: [String: (teacher: String, room: String)] = [:]
        for s in allSlots {
            if courseMap[s.courseName] == nil {
                courseMap[s.courseName] = (teacher: s.teacher, room: s.room)
            } else {
                if courseMap[s.courseName]?.teacher.isEmpty == true && !s.teacher.isEmpty {
                    courseMap[s.courseName]?.teacher = s.teacher
                }
                if courseMap[s.courseName]?.room.isEmpty == true && !s.room.isEmpty {
                    courseMap[s.courseName]?.room = s.room
                }
            }
        }
        
        let draftItems = courseMap.map { (name, info) in
            DraftCourseItem(
                originalName: name,
                editedName: name,
                teacher: info.teacher,
                room: info.room,
                action: .create,
                isSelected: true
            )
        }.sorted { $0.originalName < $1.originalName }
        
        return TimetableImportDraft(
            semester: extractedSemester,
            studentName: extractedStudentName,
            className: extractedClassName,
            schoolName: extractedSchoolName,
            slots: allSlots,
            items: draftItems,
            warnings: warnings
        )
    }

    /// 辅助：按列空间投影解析单页中的课程卡片
    private static func parsePageSlots(page: PDFPage, semester: String, warnings: inout [String]) -> [TimetableSlot] {
        var pageSlots: [TimetableSlot] = []
        let pageBounds = page.bounds(for: .mediaBox)
        let pageWidth = pageBounds.width > 0 ? pageBounds.width : 612.0
        let pageHeight = pageBounds.height > 0 ? pageBounds.height : 792.0
        
        let rawText = normalizeText(page.string ?? "")
        
        // 如果页面没有可提取文字（如纯图片/扫描版），尝试调用 Vision OCR 兜底
        if rawText.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
            #if canImport(Vision) && canImport(UIKit)
            let ocrSlots = parseWithVisionOCR(page: page, semester: semester, warnings: &warnings)
            if !ocrSlots.isEmpty { return ocrSlots }
            #endif
        }
        
        // 标准 7 列网格边界划分 (覆盖星期一 ~ 星期日)
        // 适用于标准 A4 与 US Letter 教务课表
        let leftMargin: CGFloat = 34.0
        let rightMargin: CGFloat = pageWidth - 40.0
        let colWidth = (rightMargin - leftMargin) / 7.0
        
        var columnsText: [String] = Array(repeating: "", count: 7)
        
        // 使用精确空间选区（避免字符偏移错位）
        for colIdx in 0..<7 {
            let colX = leftMargin + CGFloat(colIdx) * colWidth
            // 选区留出上下边距，排除表头和底部页脚
            let colRect = CGRect(x: colX, y: 40.0, width: colWidth, height: pageHeight - 110.0)
            if let selection = page.selection(for: colRect), let str = selection.string {
                columnsText[colIdx] = normalizeText(str)
            }
        }
        
        // 如果 selection(for: rect) 在某些系统下返回空，按分块逻辑做备用投影
        let hasAnyCol = columnsText.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        if !hasAnyCol && !rawText.isEmpty {
            // 备用：按 ● 分割并按星期与节次投影
            let entries = rawText.components(separatedBy: "●").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            for ent in entries {
                // 探测其 day: 默认按 1 处理或从文本中提取
                if let parsed = parseEntry(day: 1, entry: ent, semester: semester) {
                    pageSlots.append(contentsOf: parsed.slots)
                }
            }
            return pageSlots
        }
        
        // 逐列分析已提取的文本块
        for dayIdx in 0..<7 {
            let colStr = columnsText[dayIdx]
            let entries = colStr.components(separatedBy: "●").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            
            for ent in entries {
                if let parsed = parseEntry(day: dayIdx + 1, entry: ent, semester: semester) {
                    pageSlots.append(contentsOf: parsed.slots)
                    if parsed.teacher.isEmpty {
                        warnings.append("「\(parsed.name)」未检测到授课教师")
                    }
                    if parsed.slots.first?.room.isEmpty == true {
                        warnings.append("「\(parsed.name)」未检测到教室信息")
                    }
                }
            }
        }
        
        return pageSlots
    }

    #if canImport(Vision) && canImport(UIKit)
    /// Vision OCR 扫描版 PDF 文本与坐标识别支持
    private static func parseWithVisionOCR(page: PDFPage, semester: String, warnings: inout [String]) -> [TimetableSlot] {
        let size = page.bounds(for: .mediaBox).size
        guard size.width > 0, size.height > 0 else { return [] }
        
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { ctx in
            UIColor.white.set()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0.0, y: size.height)
            ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
        guard let cgImage = uiImage.cgImage else { return [] }
        
        var recognizedSlots: [TimetableSlot] = []
        let request = VNRecognizeTextRequest { req, err in
            guard err == nil, let observations = req.results as? [VNRecognizedTextObservation] else { return }
            var ocrLines: [(text: String, box: CGRect)] = []
            for obs in observations {
                guard let candidate = obs.topCandidates(1).first else { continue }
                // Vision 归一化坐标转换为页面坐标
                let box = CGRect(
                    x: obs.boundingBox.origin.x * size.width,
                    y: (1.0 - obs.boundingBox.origin.y - obs.boundingBox.size.height) * size.height,
                    width: obs.boundingBox.size.width * size.width,
                    height: obs.boundingBox.size.height * size.height
                )
                ocrLines.append((text: normalizeText(candidate.string), box: box))
            }
            
            // 按 7 列投影 Vision 识别出的文字
            let leftMargin: CGFloat = 34.0
            let rightMargin: CGFloat = size.width - 40.0
            let colWidth = (rightMargin - leftMargin) / 7.0
            
            for dayIdx in 0..<7 {
                let minX = leftMargin + CGFloat(dayIdx) * colWidth
                let maxX = minX + colWidth
                let colTexts = ocrLines.filter { $0.box.midX >= minX && $0.box.midX < maxX }
                    .sorted { $0.box.minY < $1.box.minY }
                    .map { $0.text }
                    .joined(separator: " ")
                
                let entries = colTexts.components(separatedBy: "●").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                for ent in entries {
                    if let parsed = parseEntry(day: dayIdx + 1, entry: ent, semester: semester) {
                        recognizedSlots.append(contentsOf: parsed.slots)
                    }
                }
            }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        
        return recognizedSlots
    }
    #endif

    /// 兼容旧版调用的同步方法：直接将解析出的 slots 转换为默认 timetable 与 courses
    public static func parsePDF(data: Data) throws -> (timetable: TimetableData, courses: [Course]) {
        let draft = try parseTimetableDraft(data: data)
        let courses = coursesFrom(slots: draft.slots)
        let curWeek = SemesterCalendar.currentWeek()
        let timetable = TimetableData(semester: draft.semester, currentWeek: curWeek, slots: draft.slots, updatedAt: Date())
        return (timetable: timetable, courses: courses)
    }

    public static func coursesFrom(slots: [TimetableSlot]) -> [Course] {
        var dict: [String: Course] = [:]
        let colors = ["#007AFF", "#34C759", "#FF9500", "#AF52DE", "#FF2D55", "#5856D6", "#00C7BE", "#32ADE6"]
        var colorIdx = 0
        for s in slots {
            if dict[s.courseName] == nil {
                let color = colors[colorIdx % colors.count]
                colorIdx += 1
                dict[s.courseName] = Course(
                    name: s.courseName,
                    teacher: s.teacher,
                    room: s.room,
                    colorHex: color,
                    semester: s.semester,
                    source: .timetable,
                    status: .active
                )
            }
        }
        return Array(dict.values).sorted { $0.name < $1.name }
    }
}



    public static func defaultSlots() -> [TimetableSlot] {
        return [
            TimetableSlot(courseName: "线性代数A", teacher: "栗雪娟", room: "草堂9-210", day: 1, fromPeriod: 1, toPeriod: 2, weekFrom: 1, weekTo: 5, parity: "all"),
            TimetableSlot(courseName: "线性代数A", teacher: "栗雪娟", room: "草堂9-210", day: 1, fromPeriod: 1, toPeriod: 2, weekFrom: 7, weekTo: 8, parity: "all"),
            TimetableSlot(courseName: "Python程序设计", teacher: "曾珂", room: "草堂9-213", day: 1, fromPeriod: 3, toPeriod: 4, weekFrom: 1, weekTo: 5, parity: "all"),
            TimetableSlot(courseName: "大学物理实验", teacher: "庞庆", room: "4-415", day: 1, fromPeriod: 7, toPeriod: 8, weekFrom: 2, weekTo: 2, parity: "all"),
            TimetableSlot(courseName: "大学物理实验", teacher: "庞庆", room: "草堂物理实验室", day: 1, fromPeriod: 7, toPeriod: 8, weekFrom: 3, weekTo: 5, parity: "all"),
            TimetableSlot(courseName: "大学物理实验", teacher: "庞庆", room: "草堂物理实验室", day: 1, fromPeriod: 7, toPeriod: 8, weekFrom: 7, weekTo: 14, parity: "all"),
            TimetableSlot(courseName: "材料力学Ⅰ（土木类）", teacher: "刘韡", room: "草堂9-101", day: 1, fromPeriod: 7, toPeriod: 8, weekFrom: 16, weekTo: 18, parity: "all"),
            TimetableSlot(courseName: "大学物理实验", teacher: "庞庆", room: "4-415", day: 1, fromPeriod: 9, toPeriod: 10, weekFrom: 2, weekTo: 2, parity: "all"),
            TimetableSlot(courseName: "大学物理实验", teacher: "庞庆", room: "草堂物理实验室", day: 1, fromPeriod: 9, toPeriod: 10, weekFrom: 3, weekTo: 5, parity: "all"),
            TimetableSlot(courseName: "大学物理实验", teacher: "庞庆", room: "草堂物理实验室", day: 1, fromPeriod: 9, toPeriod: 10, weekFrom: 7, weekTo: 14, parity: "all"),
            TimetableSlot(courseName: "Python程序设计", teacher: "曾珂", room: "草堂8-308(机房)", day: 1, fromPeriod: 11, toPeriod: 12, weekFrom: 2, weekTo: 5, parity: "all"),
            TimetableSlot(courseName: "大学物理B2", teacher: "谢海霞", room: "草堂9-102", day: 2, fromPeriod: 1, toPeriod: 2, weekFrom: 1, weekTo: 5, parity: "all"),
            TimetableSlot(courseName: "大学物理B2", teacher: "谢海霞", room: "草堂9-102", day: 2, fromPeriod: 1, toPeriod: 2, weekFrom: 7, weekTo: 13, parity: "all"),
            TimetableSlot(courseName: "建设法规", teacher: "黄莺", room: "草堂8-204", day: 2, fromPeriod: 3, toPeriod: 4, weekFrom: 1, weekTo: 5, parity: "all"),
            TimetableSlot(courseName: "建设法规", teacher: "黄莺", room: "草堂8-204", day: 2, fromPeriod: 3, toPeriod: 4, weekFrom: 7, weekTo: 7, parity: "all"),
            TimetableSlot(courseName: "时事英语阅读（非英语专业拓展）", teacher: "解佩", room: "草堂13-315", day: 2, fromPeriod: 7, toPeriod: 8, weekFrom: 2, weekTo: 5, parity: "all"),
            TimetableSlot(courseName: "时事英语阅读（非英语专业拓展）", teacher: "解佩", room: "草堂13-315", day: 2, fromPeriod: 7, toPeriod: 8, weekFrom: 7, weekTo: 18, parity: "all"),
            TimetableSlot(courseName: "毛泽东思想和中国特色社会主义理论体系概论", teacher: "胡阿丽", room: "草堂9-311", day: 2, fromPeriod: 9, toPeriod: 10, weekFrom: 1, weekTo: 5, parity: "all"),
            TimetableSlot(courseName: "毛泽东思想和中国特色社会主义理论体系概论", teacher: "胡阿丽", room: "草堂9-311", day: 2, fromPeriod: 9, toPeriod: 10, weekFrom: 7, weekTo: 9, parity: "all"),
            TimetableSlot(courseName: "习近平新时代中国特色社会主义思想概论", teacher: "胡阿丽", room: "草堂9-311", day: 2, fromPeriod: 9, toPeriod: 10, weekFrom: 10, weekTo: 17, parity: "all"),
            TimetableSlot(courseName: "计算机辅助设计", teacher: "李睿", room: "草堂9-103", day: 2, fromPeriod: 11, toPeriod: 12, weekFrom: 1, weekTo: 4, parity: "all"),
            TimetableSlot(courseName: "MATLAB程序设计", teacher: "郭师虹/王宝顺", room: "草堂9-404", day: 3, fromPeriod: 1, toPeriod: 2, weekFrom: 9, weekTo: 12, parity: "all"),
            TimetableSlot(courseName: "智能建造导论", teacher: "门进杰", room: "草堂9-113", day: 3, fromPeriod: 1, toPeriod: 2, weekFrom: 15, weekTo: 15, parity: "all"),
            TimetableSlot(courseName: "智能建造导论", teacher: "门进杰", room: "草堂9-113", day: 3, fromPeriod: 1, toPeriod: 2, weekFrom: 16, weekTo: 16, parity: "all"),
            TimetableSlot(courseName: "线性代数A", teacher: "栗雪娟", room: "草堂9-210", day: 3, fromPeriod: 1, toPeriod: 2, weekFrom: 1, weekTo: 5, parity: "all"),
            TimetableSlot(courseName: "线性代数A", teacher: "栗雪娟", room: "草堂9-210", day: 3, fromPeriod: 1, toPeriod: 2, weekFrom: 7, weekTo: 8, parity: "all"),
            TimetableSlot(courseName: "智能建造导论", teacher: "门进杰", room: "草堂9-113", day: 3, fromPeriod: 3, toPeriod: 4, weekFrom: 15, weekTo: 15, parity: "all"),
            TimetableSlot(courseName: "智能建造导论", teacher: "门进杰", room: "草堂9-113", day: 3, fromPeriod: 3, toPeriod: 4, weekFrom: 16, weekTo: 16, parity: "all"),
            TimetableSlot(courseName: "创新创业基础", teacher: "彭莉峻", room: "草堂13-213", day: 3, fromPeriod: 3, toPeriod: 4, weekFrom: 1, weekTo: 4, parity: "all"),
            TimetableSlot(courseName: "创新创业基础", teacher: "彭莉峻", room: "草堂13-213", day: 3, fromPeriod: 3, toPeriod: 4, weekFrom: 7, weekTo: 8, parity: "all"),
            TimetableSlot(courseName: "材料力学Ⅰ（土木类）", teacher: "刘韡", room: "草堂9-101", day: 3, fromPeriod: 7, toPeriod: 8, weekFrom: 1, weekTo: 5, parity: "all"),
            TimetableSlot(courseName: "材料力学Ⅰ（土木类）", teacher: "刘韡", room: "草堂9-101", day: 3, fromPeriod: 7, toPeriod: 8, weekFrom: 7, weekTo: 18, parity: "all"),
            TimetableSlot(courseName: "计算机辅助设计", teacher: "李睿", room: "草堂9-103", day: 3, fromPeriod: 9, toPeriod: 10, weekFrom: 1, weekTo: 4, parity: "all"),
            TimetableSlot(courseName: "聆听百年--西方浪漫主义时期音乐鉴赏", teacher: "苏杰", room: "南山书院305", day: 3, fromPeriod: 9, toPeriod: 10, weekFrom: 9, weekTo: 16, parity: "all"),
            TimetableSlot(courseName: "大学物理B2", teacher: "谢海霞", room: "草堂9-102", day: 4, fromPeriod: 1, toPeriod: 2, weekFrom: 1, weekTo: 4, parity: "all"),
            TimetableSlot(courseName: "大学物理B2", teacher: "谢海霞", room: "草堂9-102", day: 4, fromPeriod: 1, toPeriod: 2, weekFrom: 6, weekTo: 13, parity: "all"),
            TimetableSlot(courseName: "形势与政策2", teacher: "贾开发", room: "草堂8-106", day: 4, fromPeriod: 1, toPeriod: 2, weekFrom: 14, weekTo: 17, parity: "all"),
            TimetableSlot(courseName: "毛泽东思想和中国特色社会主义理论体系概论", teacher: "胡阿丽", room: "草堂9-311", day: 4, fromPeriod: 3, toPeriod: 4, weekFrom: 1, weekTo: 4, parity: "all"),
            TimetableSlot(courseName: "毛泽东思想和中国特色社会主义理论体系概论", teacher: "胡阿丽", room: "草堂9-311", day: 4, fromPeriod: 3, toPeriod: 4, weekFrom: 6, weekTo: 9, parity: "all"),
            TimetableSlot(courseName: "习近平新时代中国特色社会主义思想概论", teacher: "胡阿丽", room: "草堂9-311", day: 4, fromPeriod: 3, toPeriod: 4, weekFrom: 10, weekTo: 17, parity: "all"),
            TimetableSlot(courseName: "大学生职业生涯规划与就业指导", teacher: "张紫微", room: "草堂9-416", day: 4, fromPeriod: 7, toPeriod: 8, weekFrom: 3, weekTo: 4, parity: "all"),
            TimetableSlot(courseName: "大学生职业生涯规划与就业指导", teacher: "张紫微", room: "草堂9-416", day: 4, fromPeriod: 7, toPeriod: 8, weekFrom: 6, weekTo: 12, parity: "all"),
            TimetableSlot(courseName: "MATLAB程序设计", teacher: "郭师虹/王宝顺", room: "草堂9-404", day: 4, fromPeriod: 9, toPeriod: 10, weekFrom: 9, weekTo: 12, parity: "all"),
            TimetableSlot(courseName: "建设法规", teacher: "黄莺", room: "草堂8-204", day: 4, fromPeriod: 9, toPeriod: 10, weekFrom: 1, weekTo: 3, parity: "odd"),
            TimetableSlot(courseName: "建设法规", teacher: "黄莺", room: "草堂8-204", day: 4, fromPeriod: 9, toPeriod: 10, weekFrom: 4, weekTo: 6, parity: "even"),
            TimetableSlot(courseName: "建设法规", teacher: "黄莺", room: "草堂8-204", day: 4, fromPeriod: 9, toPeriod: 10, weekFrom: 7, weekTo: 7, parity: "all"),
            TimetableSlot(courseName: "MATLAB程序设计", teacher: "郭师虹/王宝顺", room: "草堂8-308(机房)", day: 4, fromPeriod: 11, toPeriod: 12, weekFrom: 10, weekTo: 13, parity: "all"),
            TimetableSlot(courseName: "线性代数A", teacher: "栗雪娟", room: "草堂9-210", day: 5, fromPeriod: 1, toPeriod: 2, weekFrom: 2, weekTo: 3, parity: "all"),
            TimetableSlot(courseName: "线性代数A", teacher: "栗雪娟", room: "草堂9-210", day: 5, fromPeriod: 1, toPeriod: 2, weekFrom: 6, weekTo: 8, parity: "all"),
            TimetableSlot(courseName: "大学体育3", teacher: "曾孝云", room: "南山篮球场", day: 5, fromPeriod: 3, toPeriod: 4, weekFrom: 1, weekTo: 3, parity: "all"),
            TimetableSlot(courseName: "大学体育3", teacher: "曾孝云", room: "南山篮球场", day: 5, fromPeriod: 3, toPeriod: 4, weekFrom: 6, weekTo: 17, parity: "all"),
            TimetableSlot(courseName: "材料力学Ⅰ（土木类）", teacher: "刘韡", room: "草堂9-101", day: 5, fromPeriod: 7, toPeriod: 8, weekFrom: 1, weekTo: 3, parity: "all"),
            TimetableSlot(courseName: "材料力学Ⅰ（土木类）", teacher: "刘韡", room: "草堂9-101", day: 5, fromPeriod: 7, toPeriod: 8, weekFrom: 6, weekTo: 17, parity: "all"),
            TimetableSlot(courseName: "Python程序设计", teacher: "曾珂", room: "草堂9-213", day: 5, fromPeriod: 9, toPeriod: 10, weekFrom: 1, weekTo: 3, parity: "all"),
            TimetableSlot(courseName: "计算机辅助设计", teacher: "李睿", room: "草堂8-309-310(机房)", day: 5, fromPeriod: 11, toPeriod: 12, weekFrom: 2, weekTo: 3, parity: "all"),
            TimetableSlot(courseName: "计算机辅助设计", teacher: "李睿", room: "草堂8-309-310(机房)", day: 5, fromPeriod: 11, toPeriod: 12, weekFrom: 6, weekTo: 7, parity: "all"),
            TimetableSlot(courseName: "线性代数A", teacher: "栗雪娟", room: "草堂9-210", day: 6, fromPeriod: 1, toPeriod: 2, weekFrom: 6, weekTo: 6, parity: "all"),
            TimetableSlot(courseName: "大学体育3", teacher: "曾孝云", room: "南山篮球场", day: 7, fromPeriod: 1, toPeriod: 2, weekFrom: 4, weekTo: 4, parity: "all"),
            TimetableSlot(courseName: "时事英语阅读（非英语专业拓展）", teacher: "解佩", room: "草堂8-305(机房)", day: 7, fromPeriod: 7, toPeriod: 8, weekFrom: 9, weekTo: 9, parity: "all"),
            TimetableSlot(courseName: "时事英语阅读（非英语专业拓展）", teacher: "解佩", room: "草堂8-305(机房)", day: 7, fromPeriod: 7, toPeriod: 8, weekFrom: 12, weekTo: 12, parity: "all"),
            TimetableSlot(courseName: "时事英语阅读（非英语专业拓展）", teacher: "解佩", room: "草堂8-305(机房)", day: 7, fromPeriod: 7, toPeriod: 8, weekFrom: 16, weekTo: 16, parity: "all"),
            TimetableSlot(courseName: "时事英语阅读（非英语专业拓展）", teacher: "解佩", room: "草堂8-305(机房)", day: 7, fromPeriod: 9, toPeriod: 9, weekFrom: 9, weekTo: 9, parity: "all"),
            TimetableSlot(courseName: "时事英语阅读（非英语专业拓展）", teacher: "解佩", room: "草堂8-305(机房)", day: 7, fromPeriod: 9, toPeriod: 9, weekFrom: 12, weekTo: 12, parity: "all"),
            TimetableSlot(courseName: "时事英语阅读（非英语专业拓展）", teacher: "解佩", room: "草堂8-305(机房)", day: 7, fromPeriod: 9, toPeriod: 9, weekFrom: 16, weekTo: 16, parity: "all"),
        ]
    }


public struct CourseSuggester {
    public static let PERIOD_TIMES: [(start: Int, end: Int)] = [
        (start: 8 * 60 + 30, end: 9 * 60 + 15),   // 第1节 08:30 - 09:15
        (start: 9 * 60 + 20, end: 10 * 60 + 5),   // 第2节 09:20 - 10:05
        (start: 10 * 60 + 25, end: 11 * 60 + 10), // 第3节 10:25 - 11:10
        (start: 11 * 60 + 15, end: 12 * 60 + 0),  // 第4节 11:15 - 12:00
        (start: 12 * 60 + 10, end: 12 * 60 + 55), // 第5节 12:10 - 12:55
        (start: 13 * 60 + 0, end: 13 * 60 + 45),  // 第6节 13:00 - 13:45
        (start: 14 * 60 + 0, end: 14 * 60 + 45),  // 第7节 14:00 - 14:45
        (start: 14 * 60 + 50, end: 15 * 60 + 35), // 第8节 14:50 - 15:35
        (start: 15 * 60 + 45, end: 16 * 60 + 30), // 第9节 15:45 - 16:30
        (start: 16 * 60 + 35, end: 17 * 60 + 20), // 第10节 16:35 - 17:20
        (start: 19 * 60 + 0, end: 19 * 60 + 45),  // 第11节 19:00 - 19:45
        (start: 19 * 60 + 50, end: 20 * 60 + 35)  // 第12节 19:50 - 20:35
    ]
    
    public static func suggestCourse(
        now: Date = Date(),
        timetable: TimetableData,
        courses: [Course],
        history: [LessonSession] = []
    ) -> (course: Course?, reason: String) {
        let calendar = Calendar.current
        let weekdayIndex = calendar.component(.weekday, from: now)
        // Calendar weekday: 1 = Sunday, 2 = Monday ... 7 = Saturday
        let day = weekdayIndex == 1 ? 7 : (weekdayIndex - 1)
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let curMins = hour * 60 + minute
        let currentWeek = timetable.currentWeek
        
        var bestSlot: TimetableSlot?
        var minDistance = Int.max
        
        for slot in timetable.slots {
            if slot.day != day { continue }
            if currentWeek < slot.weekFrom || currentWeek > slot.weekTo { continue }
            if slot.parity == "odd" && currentWeek % 2 == 0 { continue }
            if slot.parity == "even" && currentWeek % 2 == 1 { continue }
            
            let pStart = max(1, min(PERIOD_TIMES.count, slot.fromPeriod)) - 1
            let pEnd = max(1, min(PERIOD_TIMES.count, slot.toPeriod)) - 1
            let startMins = PERIOD_TIMES[pStart].start
            let endMins = PERIOD_TIMES[pEnd].end
            
            var dist = 0
            if curMins < startMins {
                dist = startMins - curMins
            } else if curMins > endMins {
                dist = curMins - endMins
            }
            
            // 75 分钟窗口
            if dist <= 75 && dist < minDistance {
                minDistance = dist
                bestSlot = slot
            }
        }
        
        if let slot = bestSlot {
            if let cId = slot.courseId, let found = courses.first(where: { $0.id == cId }) {
                let reason = minDistance == 0 ? "正在上课中，自动为您关联" : "按平时的上课时间猜的，点此更换"
                return (course: found, reason: reason)
            } else if let found = courses.first(where: { $0.name == slot.courseName }) {
                let reason = minDistance == 0 ? "正在上课中，自动为您关联" : "按平时的上课时间猜的，点此更换"
                return (course: found, reason: reason)
            }
        }
        
        // 尝试从最近历史课堂推荐
        if let last = history.first, let cId = last.courseId, let found = courses.first(where: { $0.id == cId }) {
            return (course: found, reason: "上次录制的课程")
        }
        
        return (course: courses.first, reason: courses.isEmpty ? "未导入课表，可点此选课" : "从课表课程中选择")
    }
}
