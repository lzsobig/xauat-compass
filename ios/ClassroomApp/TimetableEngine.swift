import Foundation
import PDFKit

public struct TimetableEngine {
    public static let DAYS = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
    
    public static let RADICALS: [Character: Character] = [
        "⻄": "西", "⻩": "黄", "⻔": "门", "⻓": "长", "⻛": "风", "⻜": "飞", "⻢": "马", "⻥": "鱼",
        "⻝": "食", "⻅": "见", "⻉": "贝", "⻋": "车", "⻚": "页", "⻮": "竹", "⻰": "龙", "⻳": "龟",
        "⻆": "角", "⻘": "青", "⻬": "齐", "⻧": "卤", "⻨": "麦", "⻦": "鸟", "⻤": "鬼", "⻣": "骨",
        "⼀": "一", "⼆": "二", "⽇": "日"
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
                throw NSError(domain: "TimetableError", code: 1, userInfo: [NSLocalizedDescriptionKey: "看不懂周次：\(part)"])
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
    
    public static func parseEntry(day: Int, entry: String) -> (name: String, teacher: String, slots: [TimetableSlot])? {
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
                        parity: w.parity
                    )
                    slots.append(slot)
                }
            }
        }
        
        return (name: name, teacher: teacher, slots: slots)
    }
    
    public static func parsePDF(data: Data) throws -> (timetable: TimetableData, courses: [Course]) {
        guard let doc = PDFDocument(data: data), doc.pageCount > 0, let page = doc.page(at: 0) else {
            throw NSError(domain: "TimetableError", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法打开课表 PDF 或文档为空"])
        }
        
        struct TextItem {
            let text: String
            let x: CGFloat
            let y: CGFloat
            let width: CGFloat
        }
        
        var items: [TextItem] = []
        
        if let pageString = page.string, !pageString.isEmpty {
            let chars = Array(pageString)
            var curText = ""
            var minX: CGFloat = 1000
            var maxX: CGFloat = 0
            var curY: CGFloat = -1
            
            let charCount = min(page.numberOfCharacters, chars.count)
            for i in 0..<charCount {
                let rect = page.characterBounds(at: i)
                let ch = chars[i]
                
                if curY < 0 { curY = rect.origin.y }
                if abs(rect.origin.y - curY) > 4 || ch == "\n" {
                    if !curText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        items.append(TextItem(text: normalizeText(curText), x: minX, y: curY, width: max(10, maxX - minX)))
                    }
                    curText = ""
                    minX = rect.origin.x
                    maxX = rect.origin.x + rect.size.width
                    curY = rect.origin.y
                }
                curText.append(ch)
                minX = min(minX, rect.origin.x)
                maxX = max(maxX, rect.origin.x + rect.size.width)
            }
            if !curText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(TextItem(text: normalizeText(curText), x: minX, y: curY, width: max(10, maxX - minX)))
            }
        }
        
        // 寻找表头 星期一 ... 星期日
        var headerX: [Int: CGFloat] = [:]
        var headerY: CGFloat = 0
        for item in items {
            let clean = item.text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            for (idx, dayName) in DAYS.enumerated() {
                if clean == dayName {
                    let centerX = item.x + item.width / 2.0
                    headerX[idx] = centerX
                    if headerY == 0 || item.y > headerY { headerY = item.y }
                }
            }
        }
        
        let foundDays = headerX.keys.sorted()
        guard foundDays.count >= 5 else {
            throw NSError(domain: "TimetableError", code: 3, userInfo: [NSLocalizedDescriptionKey: "未找到课表星期表头，请确认导入的是建大教务系统课表 PDF"])
        }
        
        let firstDay = foundDays.first!
        let lastDay = foundDays.last!
        let avgColWidth = (headerX[lastDay]! - headerX[firstDay]!) / CGFloat(lastDay - firstDay)
        
        var centres: [CGFloat] = Array(repeating: 0, count: 7)
        for i in 0..<7 {
            if let x = headerX[i] {
                centres[i] = x
            } else {
                centres[i] = headerX[firstDay]! + CGFloat(i - firstDay) * avgColWidth
            }
        }
        
        // 底部页脚边界
        var bottomY: CGFloat = 0
        for item in items {
            if item.y < headerY {
                let t = item.text
                if t.contains("学分") || t.contains("://") || t.contains("for-std") {
                    if item.y > bottomY { bottomY = item.y }
                }
            }
        }
        
        // 分配到 7 列
        var columns: [[TextItem]] = Array(repeating: [], count: 7)
        for item in items {
            if item.y >= headerY - 1 || item.y <= bottomY + 1 { continue }
            let centerX = item.x + item.width / 2.0
            
            var bestCol = 0
            var minDist = abs(centres[0] - centerX)
            for c in 1..<7 {
                let d = abs(centres[c] - centerX)
                if d < minDist {
                    minDist = d
                    bestCol = c
                }
            }
            columns[bestCol].append(item)
        }
        
        var coursesDict: [String: Course] = [:]
        var allSlots: [TimetableSlot] = []
        let colors = ["#007AFF", "#34C759", "#FF9500", "#AF52DE", "#FF2D55", "#5856D6", "#00C7BE", "#32ADE6"]
        var colorIdx = 0
        
        for dayIdx in 0..<7 {
            let colItems = columns[dayIdx].sorted { $0.y > $1.y }
            let fullColText = colItems.map { $0.text }.joined(separator: "")
            let entries = fullColText.components(separatedBy: "●").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            
            for ent in entries {
                if let parsed = parseEntry(day: dayIdx + 1, entry: ent) {
                    allSlots.append(contentsOf: parsed.slots)
                    if coursesDict[parsed.name] == nil {
                        let color = colors[colorIdx % colors.count]
                        colorIdx += 1
                        let c = Course(name: parsed.name, teacher: parsed.teacher, room: parsed.slots.first?.room ?? "", colorHex: color)
                        coursesDict[parsed.name] = c
                    }
                }
            }
        }
        
        guard !coursesDict.isEmpty else {
            throw NSError(domain: "TimetableError", code: 4, userInfo: [NSLocalizedDescriptionKey: "在课表 PDF 中未找到任何课程安排"])
        }
        
        let timetable = TimetableData(currentWeek: 1, slots: allSlots, updatedAt: Date())
        let courseList = Array(coursesDict.values).sorted { $0.name < $1.name }
        return (timetable: timetable, courses: courseList)
    }
}

public struct CourseSuggester {
    public static let PERIOD_TIMES: [(start: Int, end: Int)] = [
        (start: 8 * 60 + 0, end: 8 * 60 + 45),    // 第1节 08:00 - 08:45
        (start: 8 * 60 + 55, end: 9 * 60 + 40),   // 第2节 08:55 - 09:40
        (start: 10 * 60 + 0, end: 10 * 60 + 45),  // 第3节 10:00 - 10:45
        (start: 10 * 60 + 55, end: 11 * 60 + 40), // 第4节 10:55 - 11:40
        (start: 14 * 60 + 0, end: 14 * 60 + 45),  // 第5节 14:00 - 14:45
        (start: 14 * 60 + 55, end: 15 * 60 + 40), // 第6节 14:55 - 15:40
        (start: 16 * 60 + 0, end: 16 * 60 + 45),  // 第7节 16:00 - 16:45
        (start: 16 * 60 + 55, end: 17 * 60 + 40), // 第8节 16:55 - 17:40
        (start: 19 * 60 + 0, end: 19 * 60 + 45),  // 第9节 19:00 - 19:45
        (start: 19 * 60 + 55, end: 20 * 60 + 40), // 第10节 19:55 - 20:40
        (start: 20 * 60 + 50, end: 21 * 60 + 35)  // 第11节 20:50 - 21:35
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
            
            let pStart = max(1, min(11, slot.fromPeriod)) - 1
            let pEnd = max(1, min(11, slot.toPeriod)) - 1
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
        
        if let slot = bestSlot, let found = courses.first(where: { $0.name == slot.courseName }) {
            let reason = minDistance == 0 ? "正在上课中，自动为您关联" : "按平时的上课时间猜的，点此更换"
            return (course: found, reason: reason)
        }
        
        // 尝试从最近历史课堂推荐
        if let last = history.first, let cId = last.courseId, let found = courses.first(where: { $0.id == cId }) {
            return (course: found, reason: "上次录制的课程")
        }
        
        return (course: courses.first, reason: courses.isEmpty ? "未导入课表，可点此选课" : "从课表课程中选择")
    }
}
