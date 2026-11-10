import AppKit
import PDFKit
import Foundation

// TimetableEngine's legacy parsePDF convenience method depends on the UI calendar.
// These tests exercise the real PDF parser, with a fixed week unrelated to parsing.
struct SemesterCalendar { static func currentWeek() -> Int { 1 } }

@main
struct ClassroomPDFTests {
    static func main() throws {
        let bytes = NSMutableData()
        let consumer = CGDataConsumer(data: bytes as CFMutableData)!
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for index in 0..<2 {
            pdf.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.black]
            func draw(_ string: String, x: CGFloat, y: CGFloat) {
                (string as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
            }
            draw("2026-2027-1 西安建筑科技大学 草堂 学生课表", x: 30, y: 750)
            for (day, name) in TimetableEngine.DAYS.enumerated() { draw(name, x: 66 + CGFloat(day) * 75.5, y: 700) }
            let x: CGFloat = index == 0 ? 50 : 125.5
            draw(index == 0 ? "●验收课程甲" : "●验收课程乙", x: x, y: 620)
            draw("1-2节/(1~16)周", x: x, y: 602)
            draw("◇A101◇教师甲", x: x, y: 584)
            NSGraphicsContext.restoreGraphicsState()
            pdf.endPDFPage()
        }
        pdf.closePDF()
        let draft: TimetableImportDraft
        do { draft = try TimetableEngine.parseTimetableDraft(data: bytes as Data) }
        catch {
            fflush(stdout)
            throw error
        }
        precondition(draft.semester == "2026-2027-1")
        precondition(draft.slots.count == 2, "must parse actual pages rather than a preset timetable")
        precondition(Set(draft.slots.map(\.day)) == Set([1, 2]), "weekday column coordinates must remain distinct")
        precondition(draft.slots.contains { $0.courseName.contains("验收课程甲") })
        precondition(draft.slots.contains { $0.courseName.contains("验收课程乙") })
        let weeks = try TimetableEngine.parseWeeks("1-16(单),18～20(双)")
        precondition(weeks.count == 2 && weeks[0].parity == "odd" && weeks[1].parity == "even")
        do { _ = try TimetableEngine.parseTimetableDraft(data: Data("not a PDF".utf8)); preconditionFailure("invalid PDF must report failure") }
        catch { }
        print("Production multipage PDF, real weekday columns, parity and no-preset checks passed")
    }
}
