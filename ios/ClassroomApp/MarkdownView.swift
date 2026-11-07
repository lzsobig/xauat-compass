import SwiftUI

public enum MarkdownElement: Identifiable {
    case h1(String)
    case h2(String)
    case h3(String)
    case quote(String)
    case bullet(String)
    case numberList(String, String)
    case table([String], [[String]])
    case codeBlock(String)
    case paragraph(String)
    case divider

    public var id: String {
        switch self {
        case .h1(let s): return "h1_\(s.hashValue)"
        case .h2(let s): return "h2_\(s.hashValue)"
        case .h3(let s): return "h3_\(s.hashValue)"
        case .quote(let s): return "q_\(s.hashValue)"
        case .bullet(let s): return "b_\(s.hashValue)"
        case .numberList(let n, let s): return "num_\(n)_\(s.hashValue)"
        case .table(let h, let r): return "tbl_\(h.joined().hashValue)_\(r.count)"
        case .codeBlock(let s): return "code_\(s.hashValue)"
        case .paragraph(let s): return "p_\(s.hashValue)"
        case .divider: return "div_\(UUID().uuidString)"
        }
    }
}

public struct MarkdownParser {
    public static func parse(_ text: String) -> [MarkdownElement] {
        var elements: [MarkdownElement] = []
        let rawLines = text.components(separatedBy: "\n")
        var i = 0

        while i < rawLines.count {
            let line = rawLines[i].trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                i += 1
                continue
            }

            // 1. 表格解析: 检查是否以 | 开头并包含 |
            if line.hasPrefix("|") && line.hasSuffix("|") && line.contains("|") {
                var tableLines: [String] = []
                while i < rawLines.count {
                    let tLine = rawLines[i].trimmingCharacters(in: .whitespaces)
                    if tLine.hasPrefix("|") && tLine.hasSuffix("|") {
                        tableLines.append(tLine)
                        i += 1
                    } else {
                        break
                    }
                }

                if tableLines.count >= 2 {
                    let headerCells = splitTableRow(tableLines[0])
                    var rowData: [[String]] = []
                    // 跳过第二行 |---|---| 分割行
                    let startIndex = (tableLines.count > 1 && tableLines[1].contains("---")) ? 2 : 1
                    for rIdx in startIndex..<tableLines.count {
                        let cells = splitTableRow(tableLines[rIdx])
                        if !cells.isEmpty {
                            rowData.append(cells)
                        }
                    }
                    elements.append(.table(headerCells, rowData))
                    continue
                }
            }

            // 2. 代码块解析
            if line.hasPrefix("```") {
                var codeLines: [String] = []
                i += 1
                while i < rawLines.count {
                    let cLine = rawLines[i]
                    if cLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(cLine)
                    i += 1
                }
                elements.append(.codeBlock(codeLines.joined(separator: "\n")))
                continue
            }

            // 3. 标题判断
            if line.hasPrefix("# ") {
                elements.append(.h1(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("## ") {
                elements.append(.h2(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("### ") {
                elements.append(.h3(String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("> ") {
                elements.append(.quote(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                elements.append(.bullet(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if line == "---" || line == "***" {
                elements.append(.divider)
            } else {
                // 判断有序列表如 "1. "、"2. "
                let pattern = "^(\\d+)[.、]\\s*(.*)$"
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                    let ns = line as NSString
                    let num = ns.substring(with: match.range(at: 1))
                    let content = ns.substring(with: match.range(at: 2))
                    elements.append(.numberList(num, content))
                } else {
                    elements.append(.paragraph(line))
                }
            }

            i += 1
        }

        return elements
    }

    private static func splitTableRow(_ rowStr: String) -> [String] {
        var trimmed = rowStr
        if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
        if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

public struct MarkdownContentView: View {
    let content: String
    private var elements: [MarkdownElement]

    public init(content: String) {
        self.content = content
        self.elements = MarkdownParser.parse(content)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(elements) { el in
                switch el {
                case .h1(let str):
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStringKey(str))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.primary)
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.8))
                            .frame(height: 3)
                            .cornerRadius(1.5)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                case .h2(let str):
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor)
                            .frame(width: 4, height: 18)
                        Text(LocalizedStringKey(str))
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.primary)
                    }
                    .padding(.top, 6)

                case .h3(let str):
                    Text(LocalizedStringKey(str))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .padding(.top, 4)

                case .quote(let str):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.orange)
                            .frame(width: 3)
                        Text(LocalizedStringKey(str))
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .lineSpacing(4)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)

                case .bullet(let str):
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                        Text(LocalizedStringKey(str))
                            .font(.system(size: 15))
                            .lineSpacing(3)
                    }

                case .numberList(let num, let str):
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(num).")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.accentColor)
                            .frame(minWidth: 18, alignment: .leading)
                        Text(LocalizedStringKey(str))
                            .font(.system(size: 15))
                            .lineSpacing(3)
                    }

                case .table(let headers, let rows):
                    NativeTableView(headers: headers, rows: rows)
                        .padding(.vertical, 4)

                case .codeBlock(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.primary)
                            .padding(10)
                    }
                    .background(Color(UIColor.tertiarySystemGroupedBackground))
                    .cornerRadius(8)
                    .padding(.vertical, 2)

                case .paragraph(let str):
                    Text(LocalizedStringKey(str))
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .foregroundColor(.primary)

                case .divider:
                    Divider()
                        .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - 原生优雅网格表格组件 (彻底解决 |---| 丑陋管道符问题)

struct NativeTableView: View {
    let headers: [String]
    let rows: [[String]]

    var columnWidths: [CGFloat] {
        let colCount = headers.count
        guard colCount > 0 else { return [] }
        return (0..<colCount).map { cIdx in
            let headerLen = headers[cIdx].count
            let maxRowLen = rows.compactMap { row in
                cIdx < row.count ? row[cIdx].count : 0
            }.max() ?? 0
            let effectiveLen = max(headerLen, maxRowLen)
            let calculated = CGFloat(effectiveLen) * 12.0 + 24.0
            return max(75, min(240, calculated))
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // 表头
                HStack(spacing: 0) {
                    ForEach(0..<headers.count, id: \.self) { idx in
                        let w = idx < columnWidths.count ? columnWidths[idx] : 90.0
                        Text(LocalizedStringKey(headers[idx]))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(width: w, alignment: .leading)
                        if idx < headers.count - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.3))
                                .frame(width: 1)
                        }
                    }
                }
                .background(Color(red: 0.0, green: 0.38, blue: 0.42)) // 建大蓝绿

                // 数据行
                ForEach(0..<rows.count, id: \.self) { rIdx in
                    let row = rows[rIdx]
                    Rectangle()
                        .fill(Color(UIColor.separator).opacity(0.6))
                        .frame(height: 1)

                    HStack(spacing: 0) {
                        ForEach(0..<headers.count, id: \.self) { cIdx in
                            let w = cIdx < columnWidths.count ? columnWidths[cIdx] : 90.0
                            let text = cIdx < row.count ? row[cIdx] : ""
                            Text(LocalizedStringKey(text))
                                .font(.system(size: 13))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(width: w, alignment: .leading)
                            if cIdx < headers.count - 1 {
                                Rectangle()
                                    .fill(Color(UIColor.separator).opacity(0.6))
                                    .frame(width: 1)
                            }
                        }
                    }
                    .background(rIdx % 2 == 0 ? Color(UIColor.systemBackground) : Color(UIColor.secondarySystemGroupedBackground).opacity(0.6))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(UIColor.separator), lineWidth: 1)
            )
        }
        .padding(.vertical, 4)
    }
}
