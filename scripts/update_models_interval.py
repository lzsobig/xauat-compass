import re

code = """
public enum StepfunChunkInterval: Int, Codable, CaseIterable, Sendable {
    case tenSeconds = 10
    case twentySeconds = 20
    case thirtySeconds = 30
    case fullLesson = 0
    
    public var title: String {
        switch self {
        case .tenSeconds: return "10 秒切片转写 (极速出字)"
        case .twentySeconds: return "20 秒切片转写 (推荐·语义完整)"
        case .thirtySeconds: return "30 秒切片转写 (段落更长)"
        case .fullLesson: return "课后统一转写"
        }
    }
    
    public var shortTitle: String {
        switch self {
        case .tenSeconds: return "10秒切片"
        case .twentySeconds: return "20秒切片"
        case .thirtySeconds: return "30秒切片"
        case .fullLesson: return "课后转写"
        }
    }
}
"""

for target_dir in [r'd:\antigrity\竞赛罗盘\ios\ClassroomApp', r'D:\antigrity\建大课堂录音-iOS\ios\ClassroomApp']:
    file_path = f"{target_dir}\\Models.swift"
    with open(file_path, 'r', encoding='utf-8') as f:
        text = f.read()
    if 'StepfunChunkInterval' not in text:
        marker = 'public enum LessonStatus'
        idx = text.find(marker)
        if idx != -1:
            text = text[:idx] + code.strip() + '\n\n' + text[idx:]
            with open(file_path, 'w', encoding='utf-8', newline='\n') as f:
                f.write(text)
            print(f'Added StepfunChunkInterval to {file_path}')
        else:
            print(f'Marker not found in {file_path}')
    else:
        print(f'Already present in {file_path}')
