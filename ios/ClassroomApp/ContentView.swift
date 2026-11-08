import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @EnvironmentObject var manager: ClassroomManager
    @State private var selectedTab = 0
    @State private var selectedSession: LessonSession?
    @State private var showingCoursePicker = false
    @State private var selectedCourseForRecord: Course?

    public init() {}

    public var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                RecordHomeView(
                    selectedCourse: $selectedCourseForRecord,
                    showingCoursePicker: $showingCoursePicker,
                    onOpenSession: { session in selectedSession = session }
                )
                .tabItem {
                    Label("录音", systemImage: "mic.fill")
                }
                .tag(0)

                CourseArchiveView(
                    onOpenSession: { session in selectedSession = session }
                )
                .tabItem {
                    Label("课程", systemImage: "folder.fill")
                }
                .tag(1)

                TimetableScreen(onSelectCourseForRecord: { course in
                    selectedCourseForRecord = course
                    selectedTab = 0
                })
                .tabItem {
                    Label("课表", systemImage: "calendar")
                }
                .tag(2)

                SettingsScreen()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
                .tag(3)
            }

            // 若当前正在录音且不在详情页中，显示悬浮底栏快捷回到课堂
            if let cur = manager.currentSession, selectedSession?.id != cur.id {
                VStack {
                    Spacer()
                    Button {
                        selectedSession = cur
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(manager.isPaused ? Color.orange : Color.red)
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cur.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                Text(manager.isPaused ? "已暂停 · 点击返回" : "正在录音 \(formatTime(manager.recordingElapsed))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(16)
                        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 3)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 58)
                    }
                }
            }
        }
        .sheet(item: $selectedSession) { session in
            LessonDetailView(session: session)
                .environmentObject(manager)
        }
        .sheet(isPresented: $showingCoursePicker) {
            CourseSelectionSheet(selectedCourse: $selectedCourseForRecord)
                .environmentObject(manager)
        }
        .onAppear {
            if selectedCourseForRecord == nil {
                selectedCourseForRecord = manager.suggestedCourse
            }
        }
    }

    private func formatTime(_ sec: TimeInterval) -> String {
        let whole = Int(sec)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

// MARK: - 首页录音视图 (1:1 还原移动端原貌)

struct RecordHomeView: View {
    @EnvironmentObject var manager: ClassroomManager
    @Binding var selectedCourse: Course?
    @Binding var showingCoursePicker: Bool
    var onOpenSession: (LessonSession) -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // 智能推测卡片与录音入口
                    VStack(alignment: .leading, spacing: 16) {
                        Button {
                            showingCoursePicker = true
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(hex: selectedCourse?.colorHex ?? "#0A84FF").opacity(0.15))
                                        .frame(width: 44, height: 44)
                                    Text(String(selectedCourse?.name.prefix(1) ?? "课"))
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundColor(Color(hex: selectedCourse?.colorHex ?? "#0A84FF"))
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(selectedCourse?.name ?? "未选择课程")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(.primary)
                                    Text(manager.suggestionReason)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.down")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            .padding(14)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(16)
                        }
                        .buttonStyle(PlainButtonStyle())

                        // 转录引擎快速选择 (苹果原生 vs 阶跃星辰 ASR 10秒/20秒/30秒切片)
                        HStack {
                            Text("转录方式")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Menu {
                                Button {
                                    manager.switchTranscriptionEngine(.apple)
                                } label: {
                                    HStack {
                                        Text("苹果原生输入法 (本地免Key·边说边出字)")
                                        if manager.transcriptionEngine == .apple {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }

                                Divider()

                                Section("阶跃星辰 ASR (使用您的 StepFun Key)") {
                                    Button {
                                        manager.switchTranscriptionEngine(.stepfun, interval: .tenSeconds)
                                    } label: {
                                        HStack {
                                            Text("10 秒切片转录 (高频快速出字)")
                                            if manager.transcriptionEngine == .stepfun && manager.stepfunChunkInterval == .tenSeconds {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }

                                    Button {
                                        manager.switchTranscriptionEngine(.stepfun, interval: .twentySeconds)
                                    } label: {
                                        HStack {
                                            Text("20 秒切片转录 (推荐·整句连贯准确)")
                                            if manager.transcriptionEngine == .stepfun && manager.stepfunChunkInterval == .twentySeconds {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }

                                    Button {
                                        manager.switchTranscriptionEngine(.stepfun, interval: .thirtySeconds)
                                    } label: {
                                        HStack {
                                            Text("30 秒切片转录 (长段落)")
                                            if manager.transcriptionEngine == .stepfun && manager.stepfunChunkInterval == .thirtySeconds {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }

                                    Button {
                                        manager.switchTranscriptionEngine(.stepfun, interval: .fullLesson)
                                    } label: {
                                        HStack {
                                            Text("课后整节转写 (最完整)")
                                            if manager.transcriptionEngine == .stepfun && manager.stepfunChunkInterval == .fullLesson {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: manager.transcriptionEngine == .apple ? "applelogo" : "waveform.badge.magnifyingglass")
                                        .font(.caption2)
                                    Text(manager.transcriptionEngine == .apple ? "苹果原生转录" : "阶跃 ASR (\(manager.stepfunChunkInterval.shortTitle))")
                                        .font(.caption)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 9))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color(UIColor.tertiarySystemFill))
                                .foregroundColor(.primary)
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 4)

                        HStack(spacing: 12) {
                            Button {
                                Task {
                                    await manager.startRecording(course: selectedCourse, mode: .realtime)
                                    if let cur = manager.currentSession {
                                        onOpenSession(cur)
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 16, weight: .bold))
                                    Text("实时转写")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color(red: 0.0, green: 0.42, blue: 0.40)) // 建大蓝绿主色
                                .cornerRadius(14)
                            }
                            .disabled(manager.isRecording)

                            Button {
                                Task {
                                    await manager.startRecording(course: selectedCourse, mode: .recordOnly)
                                    if let cur = manager.currentSession {
                                        onOpenSession(cur)
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                    Text("仅录音")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.primary)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color(UIColor.secondarySystemGroupedBackground))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color(UIColor.separator), lineWidth: 1)
                                )
                                .cornerRadius(14)
                            }
                            .disabled(manager.isRecording)
                        }

                        Text("录完自动保存到这门课，之后也能再换。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)
                    }
                    .padding(16)
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(20)
                    .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)

                    if !manager.errorMessage.isEmpty {
                        Text(manager.errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal)
                    }

                    // 历史录音卡片列表
                    VStack(alignment: .leading, spacing: 12) {
                        Text("录过的课会按时间显示在这里。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)

                        if manager.sessions.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "waveform.badge.magnifyingglass")
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary.opacity(0.6))
                                Text("暂无课堂录音，点上方按钮立即开始")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else {
                            ForEach(manager.sessions) { s in
                                Button {
                                    onOpenSession(s)
                                } label: {
                                    HStack(spacing: 14) {
                                        ZStack {
                                            Circle()
                                                .fill(Color(hex: courseColor(for: s.courseId)).opacity(0.12))
                                                .frame(width: 42, height: 42)
                                            Image(systemName: s.mode == .realtime ? "waveform" : "mic")
                                                .foregroundColor(Color(hex: courseColor(for: s.courseId)))
                                                .font(.system(size: 18))
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(s.title)
                                                .font(.headline)
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                            HStack(spacing: 8) {
                                                Text(formatDate(s.startedAt))
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                Text("·")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                Text(formatDuration(s.duration))
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                if !s.marks.isEmpty {
                                                    Text("· \(s.marks.count)个重点")
                                                        .font(.caption)
                                                        .foregroundColor(.orange)
                                                }
                                            }
                                        }

                                        Spacer()

                                        StatusBadge(status: s.status)
                                    }
                                    .padding(14)
                                    .background(Color(UIColor.secondarySystemGroupedBackground))
                                    .cornerRadius(14)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .padding(16)
            }
            .navigationTitle("建大课堂录音")
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func courseColor(for id: UUID?) -> String {
        guard let id = id, let c = manager.courses.first(where: { $0.id == id }) else { return "#8E8E93" }
        return c.colorHex
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }

    private func formatDuration(_ sec: TimeInterval) -> String {
        let whole = Int(sec)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

// MARK: - 课程选择弹窗

struct CourseSelectionSheet: View {
    @EnvironmentObject var manager: ClassroomManager
    @Environment(\.presentationMode) var presentationMode
    @Binding var selectedCourse: Course?
    @State private var newCourseName = ""
    @State private var showingAddAlert = false

    var body: some View {
        NavigationView {
            List {
                Section("课表与已有课程") {
                    ForEach(manager.courses) { c in
                        Button {
                            selectedCourse = c
                            presentationMode.wrappedValue.dismiss()
                        } label: {
                            HStack {
                                Circle()
                                    .fill(Color(hex: c.colorHex))
                                    .frame(width: 12, height: 12)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    if !c.room.isEmpty || !c.teacher.isEmpty {
                                        Text([c.room, c.teacher].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if selectedCourse?.id == c.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        selectedCourse = nil
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "tray")
                                .foregroundColor(.secondary)
                            Text("未归档 (不预选课程)")
                                .foregroundColor(.primary)
                            Spacer()
                            if selectedCourse == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showingAddAlert = true
                    } label: {
                        Label("新建课程分类", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("更换关联课程")
            .navigationBarItems(trailing: Button("完成") { presentationMode.wrappedValue.dismiss() })
            .alert("新建课程", isPresented: $showingAddAlert) {
                TextField("课程名称", text: $newCourseName)
                Button("取消", role: .cancel) { newCourseName = "" }
                Button("添加") {
                    let trim = newCourseName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trim.isEmpty {
                        manager.createCourse(name: trim)
                        selectedCourse = manager.courses.last
                        newCourseName = ""
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 课程归档页 (支持文件夹收纳、重命名、移动、全文检索)

struct CourseArchiveView: View {
    @EnvironmentObject var manager: ClassroomManager
    @State private var searchText = ""
    var onOpenSession: (LessonSession) -> Void

    var filteredCourses: [Course] {
        if searchText.isEmpty { return manager.courses }
        return manager.courses.filter { c in
            c.name.localizedCaseInsensitiveContains(searchText) ||
            c.teacher.localizedCaseInsensitiveContains(searchText) ||
            manager.sessions.contains(where: { $0.courseId == c.id && ($0.title.localizedCaseInsensitiveContains(searchText) || $0.fullTranscript.localizedCaseInsensitiveContains(searchText)) })
        }
    }

    var unassignedSessions: [LessonSession] {
        manager.sessions.filter { $0.courseId == nil }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("搜索课程名、课堂标题或转写正文...", text: $searchText)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color(UIColor.tertiarySystemGroupedBackground))
                    .cornerRadius(10)
                }

                Section("课程文件夹") {
                    ForEach(filteredCourses) { c in
                        let count = manager.sessions.filter { $0.courseId == c.id }.count
                        NavigationLink {
                            CourseDetailScreen(course: c, onOpenSession: onOpenSession)
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(hex: c.colorHex))
                                    .frame(width: 14, height: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.name)
                                        .font(.headline)
                                    if !c.room.isEmpty || !c.teacher.isEmpty {
                                        Text([c.room, c.teacher].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(count) 节课")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // 未归档文件夹
                    NavigationLink {
                        UnassignedDetailScreen(onOpenSession: onOpenSession)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tray.fill")
                                .foregroundColor(.secondary)
                                .frame(width: 20)
                            Text("未归档")
                                .font(.headline)
                            Spacer()
                            Text("\(unassignedSessions.count) 节课")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("课程资料库")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct CourseDetailScreen: View {
    @EnvironmentObject var manager: ClassroomManager
    let course: Course
    var onOpenSession: (LessonSession) -> Void
    @State private var sessionToMove: LessonSession?
    @State private var sessionToRename: LessonSession?
    @State private var newTitle = ""

    var courseSessions: [LessonSession] {
        manager.sessions.filter { $0.courseId == course.id }
    }

    var body: some View {
        List {
            if courseSessions.isEmpty {
                Text("本课程暂无课堂记录")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 20)
            } else {
                ForEach(courseSessions) { s in
                    Button {
                        onOpenSession(s)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.title)
                                .font(.headline)
                                .foregroundColor(.primary)
                            HStack {
                                Text(formatDate(s.startedAt))
                                Text("·")
                                Text(formatDuration(s.duration))
                                if !s.marks.isEmpty {
                                    Text("· \(s.marks.count)个重点")
                                        .foregroundColor(.orange)
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            manager.deleteSession(s)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            sessionToRename = s
                            newTitle = s.title
                        } label: {
                            Label("改名", systemImage: "pencil")
                        }
                        .tint(.blue)
                        Button {
                            sessionToMove = s
                        } label: {
                            Label("移动", systemImage: "folder")
                        }
                        .tint(.orange)
                    }
                }
            }
        }
        .navigationTitle(course.name)
        .confirmationDialog("移动到其他课程", isPresented: Binding(
            get: { sessionToMove != nil },
            set: { if !$0 { sessionToMove = nil } }
        )) {
            ForEach(manager.courses.filter { $0.id != course.id }) { target in
                Button(target.name) {
                    if let s = sessionToMove { manager.moveSession(s, to: target) }
                }
            }
            Button("移至未归档") {
                if let s = sessionToMove { manager.moveSession(s, to: nil) }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("课堂重命名", isPresented: Binding(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        )) {
            TextField("课堂标题", text: $newTitle)
            Button("取消", role: .cancel) {}
            Button("确定") {
                if let s = sessionToRename { manager.renameSession(s, newTitle: newTitle) }
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private func formatDuration(_ sec: TimeInterval) -> String {
        let whole = Int(sec)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

struct UnassignedDetailScreen: View {
    @EnvironmentObject var manager: ClassroomManager
    var onOpenSession: (LessonSession) -> Void
    @State private var sessionToMove: LessonSession?

    var unassignedSessions: [LessonSession] {
        manager.sessions.filter { $0.courseId == nil }
    }

    var body: some View {
        List {
            if unassignedSessions.isEmpty {
                Text("暂无未归档记录")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 20)
            } else {
                ForEach(unassignedSessions) { s in
                    Button {
                        onOpenSession(s)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.title)
                                .font(.headline)
                                .foregroundColor(.primary)
                            HStack {
                                Text(formatDate(s.startedAt))
                                Text("·")
                                Text(formatDuration(s.duration))
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            sessionToMove = s
                        } label: {
                            Label("归档到课程", systemImage: "folder")
                        }
                        .tint(.blue)
                        Button(role: .destructive) {
                            manager.deleteSession(s)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("未归档课堂")
        .confirmationDialog("归档到课程", isPresented: Binding(
            get: { sessionToMove != nil },
            set: { if !$0 { sessionToMove = nil } }
        )) {
            ForEach(manager.courses) { target in
                Button(target.name) {
                    if let s = sessionToMove { manager.moveSession(s, to: target) }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private func formatDuration(_ sec: TimeInterval) -> String {
        let whole = Int(sec)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

// MARK: - 课表视图 (7天周网格课表，完全对标建大官方教务与手机排版)

struct CourseCardPalette {
    let bg: Color
    let text: Color
}

private let kTimetablePalettes: [CourseCardPalette] = [
    CourseCardPalette(bg: Color(red: 0.99, green: 0.94, blue: 0.91), text: Color(red: 0.55, green: 0.23, blue: 0.17)), // 浅粉桃
    CourseCardPalette(bg: Color(red: 0.99, green: 0.89, blue: 0.93), text: Color(red: 0.62, green: 0.15, blue: 0.38)), // 嫩粉紫
    CourseCardPalette(bg: Color(red: 1.00, green: 0.95, blue: 0.78), text: Color(red: 0.57, green: 0.25, blue: 0.05)), // 暖黄姜
    CourseCardPalette(bg: Color(red: 0.95, green: 0.91, blue: 1.00), text: Color(red: 0.49, green: 0.13, blue: 0.81)), // 浅薰衣草
    CourseCardPalette(bg: Color(red: 0.99, green: 0.91, blue: 0.95), text: Color(red: 0.61, green: 0.09, blue: 0.30)), // 柔和玫粉
    CourseCardPalette(bg: Color(red: 0.86, green: 0.99, blue: 0.91), text: Color(red: 0.08, green: 0.50, blue: 0.24)), // 薄荷淡绿
    CourseCardPalette(bg: Color(red: 0.88, green: 0.95, blue: 0.99), text: Color(red: 0.01, green: 0.41, blue: 0.63)), // 冰川浅蓝
    CourseCardPalette(bg: Color(red: 1.00, green: 0.98, blue: 0.76), text: Color(red: 0.52, green: 0.30, blue: 0.05))  // 柠檬浅黄
]

struct PeriodSlotInfo {
    let period: Int
    let start: String
    let end: String
}

private let kClassPeriods: [PeriodSlotInfo] = [
    PeriodSlotInfo(period: 1, start: "08:30", end: "09:15"),
    PeriodSlotInfo(period: 2, start: "09:20", end: "10:05"),
    PeriodSlotInfo(period: 3, start: "10:25", end: "11:10"),
    PeriodSlotInfo(period: 4, start: "11:15", end: "12:00"),
    PeriodSlotInfo(period: 5, start: "12:10", end: "12:55"),
    PeriodSlotInfo(period: 6, start: "13:00", end: "13:45"),
    PeriodSlotInfo(period: 7, start: "14:00", end: "14:45"),
    PeriodSlotInfo(period: 8, start: "14:50", end: "15:35"),
    PeriodSlotInfo(period: 9, start: "15:45", end: "16:30"),
    PeriodSlotInfo(period: 10, start: "16:35", end: "17:20"),
    PeriodSlotInfo(period: 11, start: "19:00", end: "19:45"),
    PeriodSlotInfo(period: 12, start: "19:50", end: "20:35")
]

public struct SemesterCalendar {
    public static let semesterStart: Date = {
        var comp = DateComponents()
        comp.year = 2026
        comp.month = 8
        comp.day = 31
        comp.hour = 0
        comp.minute = 0
        comp.second = 0
        return Calendar(identifier: .gregorian).date(from: comp) ?? Date()
    }()

    public static func currentWeek() -> Int {
        let cal = Calendar(identifier: .gregorian)
        let diff = cal.dateComponents([.day], from: semesterStart, to: Date()).day ?? 0
        let w = (diff / 7) + 1
        return max(1, min(25, w))
    }

    public static func datesForWeek(_ week: Int) -> [Date] {
        let cal = Calendar(identifier: .gregorian)
        guard let weekStart = cal.date(byAdding: .day, value: (week - 1) * 7, to: semesterStart) else {
            return []
        }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
    }
}

struct TimetableScreen: View {
    @EnvironmentObject var manager: ClassroomManager
    var onSelectCourseForRecord: ((Course) -> Void)? = nil

    @State private var selectedWeek: Int = 10
    @State private var showingFileImporter = false
    @State private var importStatus = ""
    @State private var selectedSlotForDetail: TimetableSlot?

    let days = ["一", "二", "三", "四", "五", "六", "日"]
    let timeColWidth: CGFloat = 34.0
    let slotHeight: CGFloat = 58.0

    var weekDates: [Date] {
        SemesterCalendar.datesForWeek(selectedWeek)
    }

    var monthNumber: Int {
        guard let first = weekDates.first else { return 11 }
        return Calendar(identifier: .gregorian).component(.month, from: first)
    }

    var body: some View {
        NavigationView {
            GeometryReader { geo in
                let dayColWidth = (geo.size.width - timeColWidth) / 7.0
                let totalGridHeight = CGFloat(kClassPeriods.count) * slotHeight

                VStack(spacing: 0) {
                    // 状态提示条（导入反馈）
                    if !importStatus.isEmpty {
                        Text(importStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                            .background(Color(UIColor.tertiarySystemFill))
                    }

                    // 1. 顶部日期表头 (11月 / 一 2, 二 3, 三 4, 四 5, 五 6, 六 7, 日 8)
                    HStack(spacing: 0) {
                        // 左上角月份
                        VStack(spacing: 1) {
                            Text("\(monthNumber)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.primary)
                            Text("月")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .frame(width: timeColWidth, height: 46)

                        // 星期一到星期日
                        ForEach(0..<7, id: \.self) { i in
                            let date = i < weekDates.count ? weekDates[i] : Date()
                            let dayNum = Calendar(identifier: .gregorian).component(.day, from: date)
                            let isToday = Calendar.current.isDateInToday(date)

                            VStack(spacing: 3) {
                                Text(days[i])
                                    .font(.system(size: 12))
                                    .foregroundColor(isToday ? .primary : .secondary)

                                if isToday {
                                    Text("\(dayNum)")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 22, height: 22)
                                        .background(Color.primary)
                                        .clipShape(Circle())
                                } else {
                                    Text("\(dayNum)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary)
                                        .frame(width: 22, height: 22)
                                }
                            }
                            .frame(width: dayColWidth, height: 46)
                        }
                    }
                    .background(Color(UIColor.systemBackground))

                    Divider()

                    // 2. 课表时间轴与周网格主体
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            // 背景网格线 (水平分割线)
                            VStack(spacing: 0) {
                                ForEach(0..<kClassPeriods.count, id: \.self) { p in
                                    Rectangle()
                                        .fill(Color(UIColor.separator).opacity(0.18))
                                        .frame(height: 0.5)
                                        .offset(y: slotHeight - 0.5)
                                        .frame(height: slotHeight)
                                }
                            }
                            .offset(x: timeColWidth)

                            // 垂直列分割线
                            HStack(spacing: 0) {
                                Spacer().frame(width: timeColWidth)
                                ForEach(0..<7, id: \.self) { _ in
                                    Rectangle()
                                        .fill(Color(UIColor.separator).opacity(0.15))
                                        .frame(width: 0.5, height: totalGridHeight)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                            }

                            // 左侧节次与时间戳
                            ForEach(0..<kClassPeriods.count, id: \.self) { p in
                                let pInfo = kClassPeriods[p]
                                let y = CGFloat(p) * slotHeight
                                VStack(spacing: 1) {
                                    Text("\(pInfo.period)")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Text(pInfo.start)
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Text(pInfo.end)
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .frame(width: timeColWidth, height: slotHeight)
                                .position(x: timeColWidth / 2, y: y + slotHeight / 2)
                            }

                            // 课程彩色卡片层
                            let activeSlots = manager.timetable.slots.filter { slot in
                                selectedWeek >= slot.weekFrom &&
                                selectedWeek <= slot.weekTo &&
                                (slot.parity == "all" || (slot.parity == "odd" && selectedWeek % 2 == 1) || (slot.parity == "even" && selectedWeek % 2 == 0))
                            }

                            ForEach(activeSlots) { slot in
                                let d = slot.day - 1
                                if d >= 0 && d < 7 {
                                    let fromP = max(1, min(kClassPeriods.count, slot.fromPeriod))
                                    let toP = max(fromP, min(kClassPeriods.count, slot.toPeriod))
                                    let span = toP - fromP + 1

                                    let cardX = timeColWidth + CGFloat(d) * dayColWidth + 1.5
                                    let cardY = CGFloat(fromP - 1) * slotHeight + 1.5
                                    let cardW = max(10, dayColWidth - 3.0)
                                    let cardH = max(20, CGFloat(span) * slotHeight - 3.0)

                                    let palette = kTimetablePalettes[abs(slot.courseName.hashValue) % kTimetablePalettes.count]
                                    let roomText = slot.room.isEmpty ? "" : (slot.room.contains("草堂") ? "@ \(slot.room)" : "@ 草堂校区 \(slot.room)")

                                    VStack(spacing: 2) {
                                        Text(slot.courseName)
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundColor(palette.text)
                                            .multilineTextAlignment(.center)
                                            .lineLimit(span > 1 ? 4 : 2)

                                        if !roomText.isEmpty {
                                            Text(roomText)
                                                .font(.system(size: 9.5))
                                                .foregroundColor(palette.text.opacity(0.85))
                                                .multilineTextAlignment(.center)
                                                .lineLimit(span > 1 ? 3 : 1)
                                        }
                                    }
                                    .padding(2)
                                    .frame(width: cardW, height: cardH)
                                    .background(palette.bg)
                                    .cornerRadius(6)
                                    .position(x: cardX + cardW / 2, y: cardY + cardH / 2)
                                    .onTapGesture {
                                        selectedSlotForDetail = slot
                                    }
                                }
                            }
                        }
                        .frame(width: geo.size.width, height: totalGridHeight)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        ForEach(1...20, id: \.self) { w in
                            Button {
                                selectedWeek = w
                                manager.timetable.currentWeek = w
                                manager.saveTimetable()
                                manager.updateCourseSuggestion()
                            } label: {
                                if w == SemesterCalendar.currentWeek() {
                                    Label("第 \(w) 周 (本周)", systemImage: "checkmark")
                                } else {
                                    Text("第 \(w) 周")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("第 \(selectedWeek) 周")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.primary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(UIColor.secondarySystemFill))
                        .cornerRadius(8)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            showingFileImporter = true
                        } label: {
                            Image(systemName: "icloud.and.arrow.up")
                                .font(.system(size: 16))
                                .foregroundColor(.primary)
                        }
                    }
                }
            }
            .sheet(item: $selectedSlotForDetail) { slot in
                CourseSlotDetailSheet(slot: slot) { targetSlot in
                    let course = manager.courses.first(where: { $0.name == targetSlot.courseName }) ?? Course(
                        name: targetSlot.courseName,
                        teacher: targetSlot.teacher,
                        room: targetSlot.room,
                        colorHex: "#007AFF"
                    )
                    onSelectCourseForRecord?(course)
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        do {
                            let data = try Data(contentsOf: url)
                            try manager.importTimetable(data: data)
                            importStatus = "课表导入成功！共识别 \(manager.timetable.slots.count) 个课程节次"
                        } catch {
                            importStatus = "导入失败：\(error.localizedDescription)"
                        }
                    }
                case .failure(let err):
                    importStatus = "读取文件失败：\(err.localizedDescription)"
                }
            }
            .onAppear {
                selectedWeek = manager.timetable.currentWeek > 0 ? manager.timetable.currentWeek : SemesterCalendar.currentWeek()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - 课程卡片轻触详情弹窗 (可一键开启录音)

struct CourseSlotDetailSheet: View {
    @Environment(\.presentationMode) var presentationMode
    let slot: TimetableSlot
    var onRecord: (TimetableSlot) -> Void

    let days = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(slot.courseName)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.primary)
                    if !slot.teacher.isEmpty {
                        Label("任课教师：\(slot.teacher)", systemImage: "person.fill")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 8)

                Divider()

                VStack(spacing: 14) {
                    HStack {
                        Label("上课地点", systemImage: "mappin.and.ellipse")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(slot.room.isEmpty ? "未标注教室" : slot.room)
                            .font(.system(size: 15, weight: .semibold))
                    }

                    HStack {
                        Label("上课时间", systemImage: "clock.fill")
                            .foregroundColor(.secondary)
                        Spacer()
                        let pStart = max(1, min(kClassPeriods.count, slot.fromPeriod))
                        let pEnd = max(pStart, min(kClassPeriods.count, slot.toPeriod))
                        let tStr = "\(kClassPeriods[pStart - 1].start) - \(kClassPeriods[pEnd - 1].end)"
                        Text("星期\(days[max(0, min(6, slot.day - 1))]) 第 \(slot.fromPeriod)-\(slot.toPeriod) 节 (\(tStr))")
                            .font(.system(size: 14, weight: .semibold))
                    }

                    HStack {
                        Label("教学周次", systemImage: "calendar")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("第 \(slot.weekFrom)-\(slot.weekTo) 周\(parityDescription(slot.parity))")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .padding(16)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(14)

                Spacer()

                Button {
                    onRecord(slot)
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    HStack {
                        Image(systemName: "mic.fill")
                        Text("录制这节课")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.accentColor)
                    .cornerRadius(14)
                }
            }
            .padding(20)
            .navigationTitle("课程详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }

    private func parityDescription(_ parity: String) -> String {
        switch parity {
        case "odd": return " (单周)"
        case "even": return " (双周)"
        default: return ""
        }
    }
}

// MARK: - 设置页

struct SettingsScreen: View {
    @EnvironmentObject var manager: ClassroomManager
    @State private var showResetSuccess = false
    @State private var showKey = false

    var body: some View {
        NavigationView {
            List {
                                Section(
                    header: Text("语音转录引擎与分段模式"),
                    footer: Text(manager.transcriptionEngine == .apple ? "苹果原生：内置 iOS 本地模型，离线可用，不耗流量，边录音边实时出字。" : "阶跃星辰 ASR：基于 stepaudio-2.5-asr 云端学术模型，每 10~20 秒自动切片转录，公式与专业术语准确率极高。")
                ) {
                    Picker("转录引擎", selection: $manager.transcriptionEngine) {
                        ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())

                    if manager.transcriptionEngine == .stepfun {
                        Picker("切片转录间隔", selection: $manager.stepfunChunkInterval) {
                            ForEach(StepfunChunkInterval.allCases, id: \.self) { interval in
                                Text(interval.title).tag(interval)
                            }
                        }
                    }

                    HStack {
                        Label(
                            manager.transcriptionEngine == .apple ? "苹果原生识别引擎 (已激活)" : "阶跃星辰 ASR - \(manager.stepfunChunkInterval.shortTitle) (已激活)",
                            systemImage: manager.transcriptionEngine == .apple ? "applelogo" : "bolt.fill"
                        )
                        .font(.footnote)
                        .foregroundColor(manager.transcriptionEngine == .apple ? .accentColor : .blue)

                        Spacer()

                        Text(manager.transcriptionEngine == .apple ? "本地免Key" : "stepaudio-2.5-asr")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(UIColor.tertiarySystemFill))
                            .cornerRadius(4)
                    }
                }

                Section(
                    header: Text("AI 助教大模型 (DeepSeek 问答与笔记)"),
                    footer: Text("使用 TokenRhythm 提供的 DeepSeek v4.1 Flash，针对课堂录音实录进行问答、解题推理与 Markdown 表格笔记生成。")
                ) {
                    HStack {
                        Text("当前模型")
                        Spacer()
                        Text("deepseek-v4.1-flash-1017")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.accentColor)
                    }

                    HStack {
                        Text("接口地址")
                        Spacer()
                        TextField("Base URL", text: $manager.llmBaseURL)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 13, design: .monospaced))
                    }

                    HStack {
                        Text("模型名称")
                        Spacer()
                        TextField("Model", text: $manager.llmModel)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 13, design: .monospaced))
                    }

                    HStack {
                        Text("API Key")
                        Spacer()
                        if showKey {
                            TextField("API Key", text: $manager.llmApiKey)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 11, design: .monospaced))
                        } else {
                            SecureField("API Key", text: $manager.llmApiKey)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 11, design: .monospaced))
                        }
                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(
                    header: Text("阶跃星辰 ASR 语音识别"),
                    footer: Text("使用 stepaudio-2.5-asr 处理离线音频的高精度转写，麦克风录音时采用原生实时识别。")
                ) {
                    HStack {
                        Text("ASR 接口")
                        Spacer()
                        TextField("Base URL", text: $manager.stepfunBaseURL)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 13, design: .monospaced))
                    }

                    HStack {
                        Text("ASR 模型")
                        Spacer()
                        TextField("Model", text: $manager.stepfunAsrModel)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 13, design: .monospaced))
                    }

                    HStack {
                        Text("ASR Key")
                        Spacer()
                        if showKey {
                            TextField("Key", text: $manager.stepfunApiKey)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 11, design: .monospaced))
                        } else {
                            SecureField("Key", text: $manager.stepfunApiKey)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }
                }

                Section(
                    header: Text("录音存储与 Cloudflare R2 云端同步"),
                    footer: Text(manager.r2StorageMode.detailDescription)
                ) {
                    Picker("存储策略", selection: $manager.r2StorageMode) {
                        ForEach(AudioStorageMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    
                    Toggle("允许使用蜂窝网络上传", isOn: $manager.r2AllowCellular)
                    
                    HStack {
                        Text("云端同步 Worker")
                        Spacer()
                        TextField("https://compass.lzso.top", text: $manager.r2WorkerBaseURL)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 13, design: .monospaced))
                    }
                }

                Section {
                    Button {
                        manager.resetAIDefaults()
                        showResetSuccess = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showResetSuccess = false
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Label(showResetSuccess ? "已重置默认接口并清空本地密钥！" : "重置为默认配置 (清除敏感密钥)", systemImage: showResetSuccess ? "checkmark" : "arrow.counterclockwise")
                                .foregroundColor(showResetSuccess ? .green : .accentColor)
                            Spacer()
                        }
                    }
                }


                Section("本机存储用量") {
                    HStack {
                        Text("课堂总数")
                        Spacer()
                        Text("\(manager.sessions.count) 节")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("音频文件夹")
                        Spacer()
                        Text("ClassroomRecordings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("关于") {
                    HStack {
                        Text("应用名称")
                        Spacer()
                        Text("建大课堂录音")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.2.0 (原生原生构建)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - 课堂详情页 (从上课录音到课后复习一站式集成)

// MARK: - 自定义高触感 Tab 导航胶囊组件

struct DetailTabPill: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: isSelected ? .bold : .medium))
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .bold : .medium))
                
                if let b = badge {
                    Text(b)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.25))
                        .foregroundColor(isSelected ? .white : .primary)
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 11)
                            .fill(Color.accentColor.opacity(0.16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11)
                                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 11)
                            .fill(Color(UIColor.tertiarySystemFill).opacity(0.45))
                    }
                }
            )
            .foregroundColor(isSelected ? .accentColor : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 智能笔记生成推荐卡片

struct NoteGenerationCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(accentColor)
                    .frame(width: 44, height: 44)
                    .background(accentColor.opacity(0.12))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(14)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(accentColor.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct LessonDetailView: View {
    @EnvironmentObject var manager: ClassroomManager
    @Environment(\.presentationMode) var presentationMode
    let session: LessonSession
    @State private var currentTab: Int = 0 // 0: 文字, 1: 笔记, 2: 问答
    @State private var selectedNoteStyle: NoteStyle = .detailedOutline
    @State private var qaInput = ""
    @State private var followBottom = true
    @State private var unreadSegmentCount = 0
    @State private var showRenameAlert = false
    @State private var editTitle = ""

    var activeSession: LessonSession {
        manager.sessions.first(where: { $0.id == session.id }) ?? session
    }

    var isLiveActive: Bool {
        manager.isRecording && manager.currentSession?.id == session.id
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if isLiveActive {
                    HStack {
                        Menu {
                            Section("切换当前转录引擎") {
                                Button {
                                    manager.switchTranscriptionEngine(.stepfun, interval: .twentySeconds)
                                } label: {
                                    Label("阶跃星辰 ASR (20秒·语义完整)", systemImage: manager.transcriptionEngine == .stepfun && manager.stepfunChunkInterval == .twentySeconds ? "checkmark" : "")
                                }
                                Button {
                                    manager.switchTranscriptionEngine(.stepfun, interval: .tenSeconds)
                                } label: {
                                    Label("阶跃星辰 ASR (10秒·极速出字)", systemImage: manager.transcriptionEngine == .stepfun && manager.stepfunChunkInterval == .tenSeconds ? "checkmark" : "")
                                }
                                Button {
                                    manager.switchTranscriptionEngine(.stepfun, interval: .fullLesson)
                                } label: {
                                    Label("课后统一转写 (录中静默)", systemImage: manager.transcriptionEngine == .stepfun && manager.stepfunChunkInterval == .fullLesson ? "checkmark" : "")
                                }
                                Button {
                                    manager.switchTranscriptionEngine(.apple)
                                } label: {
                                    Label("苹果原生识别 (免Key·系统输入法)", systemImage: manager.transcriptionEngine == .apple ? "checkmark" : "")
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(manager.isPaused ? Color.orange : Color.green)
                                    .frame(width: 8, height: 8)
                                Text(manager.transcriptionEngine == .stepfun ? "阶跃 ASR (\(manager.stepfunChunkInterval.shortTitle))" : "苹果原生")
                                    .font(.system(size: 12, weight: .bold))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(UIColor.tertiarySystemFill))
                            .foregroundColor(.primary)
                            .cornerRadius(12)
                        }

                        Spacer()

                        Text(manager.isPaused ? "已暂停录音" : "正在录音")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(manager.isPaused ? .orange : .green)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                } else {
                    HStack {
                        HStack(spacing: 5) {
                            Image(systemName: activeSession.storageStatus == .cloudOnly || activeSession.storageStatus == .cloudVerified ? "icloud.fill" : (activeSession.storageStatus == .uploadFailed ? "exclamationmark.icloud.fill" : "internaldrive"))
                                .font(.system(size: 12))
                                .foregroundColor(activeSession.storageStatus == .uploadFailed ? .red : (activeSession.storageStatus == .cloudOnly || activeSession.storageStatus == .cloudVerified ? .blue : .secondary))
                            Text(activeSession.storageStatus.title)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if activeSession.storageStatus == .cloudOnly {
                            Button {
                                Task {
                                    await manager.downloadCloudAudio(for: activeSession)
                                }
                            } label: {
                                Label("下载音频到本地", systemImage: "arrow.down.circle")
                                    .font(.caption2)
                                    .foregroundColor(.accentColor)
                            }
                        } else if activeSession.storageStatus == .uploadFailed || activeSession.storageStatus == .localOnly {
                            Button {
                                manager.retryUpload(session: activeSession)
                            } label: {
                                Label("上传备份至云端", systemImage: "arrow.up.circle")
                                    .font(.caption2)
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                }

                // 自定义大触控 Tab 导航栏 (带未读/条目角标与动画)
                HStack(spacing: 6) {
                    DetailTabPill(
                        title: "实录文字",
                        systemImage: "waveform",
                        isSelected: currentTab == 0,
                        badge: activeSession.segments.count > 0 ? "\(activeSession.segments.count)" : nil
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            currentTab = 0
                        }
                    }

                    DetailTabPill(
                        title: "课堂笔记",
                        systemImage: "note.text",
                        isSelected: currentTab == 1,
                        badge: activeSession.notes.count > 0 ? "\(activeSession.notes.count)" : nil
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            currentTab = 1
                        }
                    }

                    DetailTabPill(
                        title: "AI 问答",
                        systemImage: "sparkles",
                        isSelected: currentTab == 2,
                        badge: activeSession.qaPairs.count > 0 ? "\(activeSession.qaPairs.count)" : nil
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            currentTab = 2
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(UIColor.secondarySystemGroupedBackground))

                Divider()

                // 主体内容区：支持全屏横向自然滑动切换
                TabView(selection: $currentTab) {
                    TranscriptTabView(
                        session: activeSession,
                        isLive: isLiveActive,
                        followBottom: $followBottom,
                        unreadCount: $unreadSegmentCount,
                        onAskAboutSegment: { seg, q in
                            manager.askQuestion(for: activeSession, query: q, segment: seg)
                            withAnimation { currentTab = 2 }
                        },
                        onSwitchToTab: { tab in
                            withAnimation { currentTab = tab }
                        }
                    )
                    .tag(0)

                    NotesTabView(
                        session: activeSession,
                        selectedStyle: $selectedNoteStyle,
                        onSwitchToQA: {
                            withAnimation { currentTab = 2 }
                        }
                    )
                    .tag(1)

                    QATabView(
                        session: activeSession,
                        inputText: $qaInput,
                        onCitationTapped: { sec in
                            withAnimation { currentTab = 0 }
                            manager.playAudio(session: activeSession, seekTo: sec)
                        }
                    )
                    .tag(2)
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))

                // 底部录音控制栏或播放条
                if isLiveActive {
                    LiveRecordingControlBar(session: activeSession)
                } else if currentTab == 0 {
                    AudioPlayerControlBar(session: activeSession)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(activeSession.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(formatDuration(isLiveActive ? manager.recordingElapsed : activeSession.duration))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func formatDuration(_ sec: TimeInterval) -> String {
        let whole = Int(sec)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

// MARK: - Tab 1: 文字页面

struct TranscriptTabView: View {
    @EnvironmentObject var manager: ClassroomManager
    let session: LessonSession
    let isLive: Bool
    @Binding var followBottom: Bool
    @Binding var unreadCount: Int
    var onAskAboutSegment: ((TranscriptSegment, String) -> Void)? = nil
    var onSwitchToTab: ((Int) -> Void)? = nil

    @State private var selectedSegmentForQA: TranscriptSegment?
    @State private var isSelectMode: Bool = false
    @State private var selectedIds: Set<UUID> = []
    @State private var toastMessage: String? = nil

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 多选操作顶栏
                if !session.segments.isEmpty && !isLive {
                    HStack {
                        if isSelectMode {
                            Button("退出多选") {
                                isSelectMode = false
                                selectedIds.removeAll()
                            }
                            .font(.subheadline)

                            Spacer()

                            Text("已选 \(selectedIds.count) 段")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer()

                            Button(selectedIds.count == session.segments.count ? "取消全选" : "全选") {
                                if selectedIds.count == session.segments.count {
                                    selectedIds.removeAll()
                                } else {
                                    selectedIds = Set(session.segments.map { $0.id })
                                }
                            }
                            .font(.subheadline)
                        } else {
                            Spacer()
                            Button {
                                isSelectMode = true
                            } label: {
                                Label("多选复制", systemImage: "checklist")
                                    .font(.subheadline)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color(UIColor.tertiarySystemFill))
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    Divider()
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                        // 顶部大计时与实时模式指示
                        if isLive {
                            VStack(spacing: 8) {
                                Text(formatDuration(manager.recordingElapsed))
                                    .font(.system(size: 42, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.primary)
                                Menu {
                                    Button {
                                        manager.switchTranscriptionEngine(.apple)
                                    } label: {
                                        HStack {
                                            Text("苹果原生输入法 (本地边说边出字)")
                                            if manager.transcriptionEngine == .apple {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }

                                    Section("阶跃星辰 ASR (使用您的 StepFun Key)") {
                                        Button {
                                            manager.switchTranscriptionEngine(.stepfun, interval: .tenSeconds)
                                        } label: {
                                            HStack {
                                                Text("10 秒切片转录 (高频快速)")
                                                if manager.transcriptionEngine == .stepfun && manager.stepfunChunkInterval == .tenSeconds {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }

                                        Button {
                                            manager.switchTranscriptionEngine(.stepfun, interval: .twentySeconds)
                                        } label: {
                                            HStack {
                                                Text("20 秒切片转录 (推荐·整句连贯)")
                                                if manager.transcriptionEngine == .stepfun && manager.stepfunChunkInterval == .twentySeconds {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }

                                        Button {
                                            manager.switchTranscriptionEngine(.stepfun, interval: .thirtySeconds)
                                        } label: {
                                            HStack {
                                                Text("30 秒切片转录 (长段落)")
                                                if manager.transcriptionEngine == .stepfun && manager.stepfunChunkInterval == .thirtySeconds {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(manager.isPaused ? Color.orange : (manager.transcriptionEngine == .apple ? Color.green : Color.blue))
                                            .frame(width: 8, height: 8)
                                        
                                        if manager.isPaused {
                                            Text("已暂停录音 (点击切换转录)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        } else if manager.transcriptionEngine == .apple {
                                            Text("苹果原生实时转录中 (点击可换阶跃ASR)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        } else {
                                            HStack(spacing: 4) {
                                                Text("阶跃星辰 ASR (\(manager.stepfunChunkInterval.shortTitle)) 转写中")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                if manager.isChunkTranscribing {
                                                    ProgressView()
                                                        .scaleEffect(0.6)
                                                }
                                            }
                                        }
                                        
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 8))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color(UIColor.tertiarySystemFill).opacity(0.6))
                                    .cornerRadius(12)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(16)
                        }

                        if session.segments.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "waveform.slash")
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text(session.mode == .recordOnly ? "仅录音模式：课后可一键离线补转写" : "等待语音输入中...")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                if session.mode == .recordOnly && !isLive {
                                    Button {
                                        manager.transcribeOffline(for: session)
                                    } label: {
                                        Label("开始转写录音", systemImage: "sparkles")
                                            .font(.headline)
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 10)
                                            .background(Color.accentColor)
                                            .foregroundColor(.white)
                                            .cornerRadius(12)
                                    }
                                    .disabled(manager.isTranscribingOffline)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 50)
                        } else {
                            ForEach(session.segments) { seg in
                                HStack(alignment: .top, spacing: 10) {
                                    if isSelectMode {
                                        Button {
                                            if selectedIds.contains(seg.id) {
                                                selectedIds.remove(seg.id)
                                            } else {
                                                selectedIds.insert(seg.id)
                                            }
                                        } label: {
                                            Image(systemName: selectedIds.contains(seg.id) ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 20))
                                                .foregroundColor(selectedIds.contains(seg.id) ? .accentColor : .secondary)
                                        }
                                        .padding(.top, 2)
                                    }

                                    Button {
                                        if manager.hasAudioFile(for: session) {
                                            manager.playAudio(session: session, seekTo: seg.startTime)
                                        }
                                    } label: {
                                        Text(formatDuration(seg.startTime))
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color(UIColor.tertiarySystemFill))
                                            .foregroundColor(.accentColor)
                                            .cornerRadius(6)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        if seg.isMarked {
                                            Label("重点标记", systemImage: "bookmark.fill")
                                                .font(.caption2)
                                                .foregroundColor(.orange)
                                        }
                                        Text(seg.text)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                            .textSelection(.enabled)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if isSelectMode {
                                            if selectedIds.contains(seg.id) {
                                                selectedIds.remove(seg.id)
                                            } else {
                                                selectedIds.insert(seg.id)
                                            }
                                        }
                                    }
                                    
                                    Spacer()

                                    if !isSelectMode {
                                        Button {
                                            selectedSegmentForQA = seg
                                        } label: {
                                            Image(systemName: "sparkles")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(.accentColor)
                                                .padding(6)
                                                .background(Color.accentColor.opacity(0.12))
                                                .clipShape(Circle())
                                        }
                                    }
                                }
                                .padding(12)
                                .background(selectedIds.contains(seg.id) ? Color.accentColor.opacity(0.1) : (seg.isMarked ? Color.orange.opacity(0.08) : Color(UIColor.secondarySystemGroupedBackground)))
                                .cornerRadius(12)
                                .id(seg.id)
                                .contextMenu {
                                    Button {
                                        selectedSegmentForQA = seg
                                    } label: {
                                        Label("针对此段提问 (AI)", systemImage: "bubble.left.and.text.bubble.right")
                                    }
                                    Button {
                                        manager.toggleSegmentMark(session: session, segmentId: seg.id)
                                    } label: {
                                        Label(seg.isMarked ? "取消重点" : "标为重点", systemImage: seg.isMarked ? "bookmark.slash" : "bookmark.fill")
                                    }
                                    Button {
                                        UIPasteboard.general.string = seg.text
                                        toastMessage = "已复制该段文字"
                                    } label: {
                                        Label("复制本段文字", systemImage: "doc.on.doc")
                                    }
                                    Button {
                                        isSelectMode = true
                                        selectedIds.insert(seg.id)
                                    } label: {
                                        Label("多选此段及其他", systemImage: "checklist")
                                    }
                                    Button {
                                        manager.playAudio(session: session, seekTo: seg.startTime)
                                    } label: {
                                        Label("从本句开始播放", systemImage: "play.circle")
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .onChange(of: session.segments.count) { _ in
                    if followBottom, let last = session.segments.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // 悬浮回到底部气泡
            if !followBottom && unreadCount > 0 {
                VStack {
                    Spacer()
                    Button {
                        followBottom = true
                        unreadCount = 0
                    } label: {
                        HStack(spacing: 6) {
                            Text("最新 \(unreadCount) 段文字")
                            Image(systemName: "arrow.down")
                        }
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                        .shadow(radius: 4)
                    }
                    .padding(.bottom, 70)
                }
            }
        }

        // 底部多选复制悬浮操作栏
        if isSelectMode && !selectedIds.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text("已选择 \(selectedIds.count) 段语音实录")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        let chosen = session.segments.filter { selectedIds.contains($0.id) }
                            .sorted { $0.startTime < $1.startTime }
                        let result = chosen.map { "[\(formatDuration($0.startTime))] \($0.text)" }.joined(separator: "\n\n")
                        UIPasteboard.general.string = result
                        toastMessage = "已复制 \(chosen.count) 段文字到剪贴板"
                        isSelectMode = false
                        selectedIds.removeAll()
                    } label: {
                        Label("复制所选文字", systemImage: "doc.on.doc")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(UIColor.systemBackground))
            }
        }

    // 浮层提示 Toast
    if let msg = toastMessage {
        VStack {
            Spacer()
            Text(msg)
                .font(.subheadline)
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.85))
                .cornerRadius(20)
                .padding(.bottom, 60)
        }
        .transition(.opacity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    toastMessage = nil
                }
            }
        }
    }
}
.sheet(item: $selectedSegmentForQA) { seg in
            SegmentQASheet(session: session, segment: seg) { question in
                onAskAboutSegment?(seg, question)
            }
        }
    }

    private func formatDuration(_ sec: TimeInterval) -> String {
        let whole = Int(sec)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

// MARK: - 选段专属 AI 追问弹窗

struct SegmentQASheet: View {
    @Environment(\.presentationMode) var presentationMode
    let session: LessonSession
    let segment: TranscriptSegment
    var onAsk: (String) -> Void

    @State private var customQuestion = ""

    let defaultPrompts = [
        "深入解释这句原话的含义与背景",
        "这句话涉及哪些期末考点与易错陷阱？",
        "帮我推导这句话里的公式或逻辑推演",
        "用通俗生活案例比喻说明本句概念"
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 原文卡片
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("课堂原话引用 [\(formatTime(segment.startTime))]", systemImage: "quote.opening")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.accentColor)
                            Spacer()
                        }
                        Text(segment.text)
                            .font(.system(size: 15))
                            .foregroundColor(.primary)
                            .lineSpacing(4)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(UIColor.tertiarySystemFill))
                            .cornerRadius(10)
                    }
                    .padding(14)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(14)

                    // 快捷追问
                    VStack(alignment: .leading, spacing: 10) {
                        Text("快捷追问方向")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.secondary)
                        ForEach(defaultPrompts, id: \.self) { prompt in
                            Button {
                                onAsk(prompt)
                                presentationMode.wrappedValue.dismiss()
                            } label: {
                                HStack {
                                    Text(prompt)
                                        .font(.system(size: 14))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.right.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                                .padding(12)
                                .background(Color(UIColor.secondarySystemGroupedBackground))
                                .cornerRadius(10)
                            }
                        }
                    }

                    // 自定义提问
                    VStack(alignment: .leading, spacing: 10) {
                        Text("自定义提问")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            TextField("例如：这句话里的变量分别代表什么？", text: $customQuestion)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Button {
                                let q = customQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !q.isEmpty else { return }
                                onAsk(q)
                                presentationMode.wrappedValue.dismiss()
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(.accentColor)
                            }
                            .disabled(customQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("针对选段提问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }

    private func formatTime(_ sec: TimeInterval) -> String {
        let whole = Int(sec)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

// MARK: - Tab 2: 笔记页面

struct NotesTabView: View {
    @EnvironmentObject var manager: ClassroomManager
    let session: LessonSession
    @Binding var selectedStyle: NoteStyle
    var onSwitchToQA: (() -> Void)? = nil
    @State private var copiedNotice = false

    var currentNote: LessonNote? {
        session.notes.first(where: { $0.style == selectedStyle })
    }

    var body: some View {
        VStack(spacing: 0) {
            // 样式选择胶囊 (大按钮，更易触控)
            HStack(spacing: 8) {
                ForEach(NoteStyle.allCases, id: \.self) { style in
                    let isSel = selectedStyle == style
                    Button {
                        withAnimation { selectedStyle = style }
                    } label: {
                        Text(style.title)
                            .font(.system(size: 13, weight: isSel ? .bold : .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(isSel ? Color.accentColor : Color(UIColor.tertiarySystemFill))
                            .foregroundColor(isSel ? .white : .primary)
                            .cornerRadius(12)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 生成中动画指示器
                    if manager.isGeneratingNotes {
                        HStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.1)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("DeepSeek 正在精读课堂实录...")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.primary)
                                Text("正在生成【\(selectedStyle.title)】，约需数秒...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(14)
                    }

                    if let note = currentNote {
                        MarkdownContentView(content: note.content)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(16)

                        HStack(spacing: 12) {
                            Button {
                                UIPasteboard.general.string = note.content
                                copiedNotice = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedNotice = false
                                }
                            } label: {
                                Label(copiedNotice ? "已复制！" : "复制全部笔记", systemImage: copiedNotice ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 14, weight: .semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color(UIColor.tertiarySystemFill))
                                    .foregroundColor(.primary)
                                    .cornerRadius(10)
                            }

                            Button {
                                manager.generateNotes(for: session, style: selectedStyle)
                            } label: {
                                Label("重新生成", systemImage: "arrow.clockwise")
                                    .font(.system(size: 14))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color(UIColor.tertiarySystemFill))
                                    .foregroundColor(.secondary)
                                    .cornerRadius(10)
                            }
                            .disabled(manager.isGeneratingNotes)

                            Spacer()

                            Button {
                                onSwitchToQA?()
                            } label: {
                                Label("针对笔记提问", systemImage: "sparkles")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.horizontal, 4)
                    } else if !manager.isGeneratingNotes {
                        // 空白状态：提供 3 大专业提炼卡片，一键触控生成
                        VStack(spacing: 16) {
                            VStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 36))
                                    .foregroundColor(.accentColor)
                                Text("智能课堂笔记")
                                    .font(.title3.bold())
                                Text("由 DeepSeek 深度理解整堂课语音实录，生成专业结构化笔记")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 10)

                            VStack(spacing: 10) {
                                NoteGenerationCard(
                                    title: "系统详细提纲",
                                    subtitle: "定理推导过程、板书架构与知识层级全面梳理",
                                    icon: "list.bullet.rectangle",
                                    accentColor: .blue
                                ) {
                                    selectedStyle = .detailedOutline
                                    manager.generateNotes(for: session, style: .detailedOutline)
                                }

                                NoteGenerationCard(
                                    title: "核心公式与要点速记",
                                    subtitle: "提炼核心定理、公式符号、适用条件与易混淆考点",
                                    icon: "function",
                                    accentColor: .green
                                ) {
                                    selectedStyle = .keyPoints
                                    manager.generateNotes(for: session, style: .keyPoints)
                                }

                                NoteGenerationCard(
                                    title: "期末重点与作业要求",
                                    subtitle: "聚焦老师反复强调的作业/实验重点与考查核心",
                                    icon: "checkmark.seal",
                                    accentColor: .orange
                                ) {
                                    selectedStyle = .examReview
                                    manager.generateNotes(for: session, style: .examReview)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(16)
            }
        }
    }
}

// MARK: - Tab 3// MARK: - Tab 3: 问答页面

struct QATabView: View {
    @EnvironmentObject var manager: ClassroomManager
    let session: LessonSession
    @Binding var inputText: String
    var onCitationTapped: (TimeInterval) -> Void

    let quickQuestions = [
        "这节课讲了哪些核心公式？",
        "老师强调了哪些考试或作业要求？",
        "总结本节课的核心结论与考点"
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 快捷问题推荐滑动胶囊
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(quickQuestions, id: \.self) { q in
                                Button {
                                    manager.askQuestion(for: session, query: q)
                                } label: {
                                    Text(q)
                                        .font(.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color(UIColor.tertiarySystemFill))
                                        .cornerRadius(14)
                                }
                                .disabled(manager.isAskingQA)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }

                    if session.qaPairs.isEmpty && !manager.isAskingQA {
                        VStack(spacing: 16) {
                            VStack(spacing: 6) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 38))
                                    .foregroundColor(.accentColor)
                                Text("课堂 AI 助教")
                                    .font(.title3.bold())
                                Text("随时针对课堂讲解中的疑难点、定理推导与考点提问")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 16)

                            VStack(spacing: 10) {
                                ForEach(quickQuestions, id: \.self) { q in
                                    Button {
                                        manager.askQuestion(for: session, query: q)
                                    } label: {
                                        HStack {
                                            Image(systemName: "questionmark.circle.fill")
                                                .foregroundColor(.accentColor)
                                            Text(q)
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundColor(.primary)
                                            Spacer()
                                            Image(systemName: "arrow.up.circle.fill")
                                                .foregroundColor(.accentColor)
                                        }
                                        .padding(14)
                                        .background(Color(UIColor.secondarySystemGroupedBackground))
                                        .cornerRadius(12)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.vertical, 10)
                    } else {
                        ForEach(session.qaPairs) { pair in
                            VStack(alignment: .leading, spacing: 8) {
                                // 用户提问
                                HStack {
                                    Spacer()
                                    Text(pair.question)
                                        .font(.subheadline)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(Color.accentColor)
                                        .cornerRadius(16)
                                }

                                // AI 回答
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                        .padding(6)
                                        .background(Color(red: 0.0, green: 0.42, blue: 0.40))
                                        .clipShape(Circle())

                                    VStack(alignment: .leading, spacing: 8) {
                                        MarkdownContentView(content: pair.answer)

                                        if let sec = pair.citationSeconds {
                                            Button {
                                                onCitationTapped(sec)
                                            } label: {
                                                Label("定位到实录：\(formatTime(sec))", systemImage: "clock.arrow.circlepath")
                                                    .font(.caption2)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.accentColor.opacity(0.12))
                                                    .cornerRadius(6)
                                            }
                                        }
                                    }
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(UIColor.secondarySystemGroupedBackground))
                                    .cornerRadius(16)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    // AI 正在思考回答动态卡片
                    if manager.isAskingQA {
                        HStack(alignment: .top, spacing: 10) {
                            ProgressView()
                                .scaleEffect(0.9)
                                .padding(6)
                            Text("DeepSeek v4.1 Flash 正在精读课堂实录并生成解答...")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(14)
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 8)
            }

            // 底部提问输入栏 (支持回车一键发送)
            Divider()
            HStack(spacing: 8) {
                TextField("向课堂 AI 提问任何公式或知识点...", text: $inputText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onSubmit {
                        let q = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !q.isEmpty {
                            manager.askQuestion(for: session, query: q)
                            inputText = ""
                        }
                    }

                Button {
                    let q = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !q.isEmpty {
                        manager.askQuestion(for: session, query: q)
                        inputText = ""
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.accentColor)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.isAskingQA)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(UIColor.secondarySystemGroupedBackground))
        }
    }

    private func formatTime(_ sec: TimeInterval) -> String {
        let whole = Int(sec)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}


// MARK: - 底部录音控制栏

struct LiveRecordingControlBar: View {
    @EnvironmentObject var manager: ClassroomManager
    let session: LessonSession
    @State private var showingStopConfirm = false

    var body: some View {
        HStack(spacing: 16) {
            Button {
                manager.isPaused ? manager.resumeRecording() : manager.pauseRecording()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: manager.isPaused ? "play.fill" : "pause.fill")
                    Text(manager.isPaused ? "继续" : "暂停")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color(UIColor.tertiarySystemFill))
                .foregroundColor(.primary)
                .cornerRadius(12)
            }

            Button {
                manager.markMoment()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bookmark.fill")
                    Text("标重点")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.orange.opacity(0.15))
                .foregroundColor(.orange)
                .cornerRadius(12)
            }
            .disabled(manager.isPaused)

            Button {
                showingStopConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    Text("结束")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.red)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .alert("结束本节课堂录制？", isPresented: $showingStopConfirm) {
            Button("继续录音", role: .cancel) {}
            Button("结束并保存", role: .destructive) {
                manager.stopRecording()
            }
        }
    }
}

// MARK: - 音频回放控制条

struct AudioPlayerControlBar: View {
    @EnvironmentObject var manager: ClassroomManager
    let session: LessonSession

    let speedOptions: [Float] = [1.0, 1.25, 1.5, 2.0]

    var body: some View {
        if manager.hasAudioFile(for: session) {
            VStack(spacing: 6) {
                HStack {
                    Label(
                        manager.hasLocalAudio(for: session) ? "本地离线音频" : "云端 R2 流式播放 (免占本地空间)",
                        systemImage: manager.hasLocalAudio(for: session) ? "internaldrive" : "icloud"
                    )
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                    Spacer()

                    if !manager.hasLocalAudio(for: session) {
                        Button {
                            Task {
                                await manager.downloadCloudAudio(for: session)
                            }
                        } label: {
                            Text("下载到本地")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }
                    }
                }

                // 滑动进度条
            Slider(
                value: Binding(
                    get: { manager.playbackTime },
                    set: { manager.seekAudio(to: $0) }
                ),
                in: 0...max(1.0, manager.playbackDuration)
            )
            .accentColor(.accentColor)

            HStack {
                Text(formatTime(manager.playbackTime))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatTime(manager.playbackDuration))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 16) {
                Button {
                    if manager.isPlayingAudio {
                        manager.pauseAudio()
                    } else {
                        manager.playAudio(session: session)
                    }
                } label: {
                    Image(systemName: manager.isPlayingAudio ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                        .foregroundColor(.accentColor)
                }

                Spacer()

                // 倍速切换
                HStack(spacing: 6) {
                    ForEach(speedOptions, id: \.self) { rate in
                        Button {
                            manager.setPlaybackRate(rate)
                        } label: {
                            Text(String(format: "%.2gx", rate))
                                .font(.system(size: 11, weight: manager.playbackRate == rate ? .bold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(manager.playbackRate == rate ? Color.accentColor : Color(UIColor.tertiarySystemFill))
                                .foregroundColor(manager.playbackRate == rate ? .white : .primary)
                                .cornerRadius(8)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        } else {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 15))
                Text("课堂文字与 AI 纪要已安全归档（未保留音频，已释放手机存储）")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func formatTime(_ sec: TimeInterval) -> String {
        let whole = Int(sec)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

// MARK: - 辅助组件

struct StatusBadge: View {
    let status: LessonStatus

    var body: some View {
        Text(status.title)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .cornerRadius(6)
    }

    private var color: Color {
        switch status {
        case .recording: return .green
        case .paused: return .orange
        case .interrupted: return .red
        case .completed: return .secondary
        }
    }
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch clean.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 122, 255)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
