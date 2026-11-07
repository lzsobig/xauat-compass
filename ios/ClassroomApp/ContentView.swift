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

                TimetableScreen()
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
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
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

                        // 双模式入口
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

// MARK: - 课表视图 (PDF 导入 + 1~20周课表)

struct TimetableScreen: View {
    @EnvironmentObject var manager: ClassroomManager
    @State private var selectedWeek: Int = 1
    @State private var showingFileImporter = false
    @State private var importStatus = ""

    let days = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 周次横向选择栏
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(1...20, id: \.self) { w in
                            Button {
                                selectedWeek = w
                                manager.timetable.currentWeek = w
                                manager.saveTimetable()
                                manager.updateCourseSuggestion()
                            } label: {
                                Text("第\(w)周")
                                    .font(.subheadline)
                                    .fontWeight(selectedWeek == w ? .bold : .regular)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(selectedWeek == w ? Color.accentColor : Color(UIColor.secondarySystemFill))
                                    .foregroundColor(selectedWeek == w ? .white : .primary)
                                    .cornerRadius(12)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(Color(UIColor.secondarySystemGroupedBackground))

                if !importStatus.isEmpty {
                    Text(importStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                }

                // 课表格子
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(1...7, id: \.self) { day in
                            let daySlots = manager.timetable.slots.filter { slot in
                                slot.day == day &&
                                selectedWeek >= slot.weekFrom &&
                                selectedWeek <= slot.weekTo &&
                                (slot.parity == "all" || (slot.parity == "odd" && selectedWeek % 2 == 1) || (slot.parity == "even" && selectedWeek % 2 == 0))
                            }.sorted { $0.fromPeriod < $1.fromPeriod }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("星期\(days[day - 1])")
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                    .foregroundColor(.secondary)

                                if daySlots.isEmpty {
                                    Text("无课程安排")
                                        .font(.caption)
                                        .foregroundColor(.secondary.opacity(0.6))
                                        .padding(.vertical, 4)
                                } else {
                                    ForEach(daySlots) { slot in
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("第\(slot.fromPeriod)-\(slot.toPeriod)节")
                                                    .font(.caption)
                                                    .fontWeight(.semibold)
                                                    .foregroundColor(.accentColor)
                                                Text(slot.courseName)
                                                    .font(.body)
                                                    .fontWeight(.semibold)
                                                if !slot.room.isEmpty || !slot.teacher.isEmpty {
                                                    Text([slot.room, slot.teacher].filter { !$0.isEmpty }.joined(separator: " · "))
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                            Spacer()
                                        }
                                        .padding(12)
                                        .background(Color(UIColor.secondarySystemGroupedBackground))
                                        .cornerRadius(12)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
            .navigationTitle("建大课表")
            .toolbar {
                Button {
                    showingFileImporter = true
                } label: {
                    Label("导入 PDF", systemImage: "doc.badge.plus")
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
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - 设置页

struct SettingsScreen: View {
    @EnvironmentObject var manager: ClassroomManager
    @State private var serverUrl = "http://127.0.0.1:4180"
    @State private var deviceAuthCode = ""

    var body: some View {
        NavigationView {
            List {
                Section("在线服务与设备认证") {
                    HStack {
                        Text("服务地址")
                        Spacer()
                        TextField("http://...", text: $serverUrl)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("6位授权码")
                        Spacer()
                        TextField("无需输密码", text: $deviceAuthCode)
                            .multilineTextAlignment(.trailing)
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
                // 顶部 3-Tab 切换栏: 文字 / 笔记 / 问答
                Picker("课堂模块", selection: $currentTab) {
                    Text("文字").tag(0)
                    Text("笔记").tag(1)
                    Text("问答").tag(2)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(UIColor.secondarySystemGroupedBackground))

                Divider()

                // 主体内容区
                Group {
                    if currentTab == 0 {
                        TranscriptTabView(
                            session: activeSession,
                            isLive: isLiveActive,
                            followBottom: $followBottom,
                            unreadCount: $unreadSegmentCount
                        )
                    } else if currentTab == 1 {
                        NotesTabView(
                            session: activeSession,
                            selectedStyle: $selectedNoteStyle
                        )
                    } else {
                        QATabView(
                            session: activeSession,
                            inputText: $qaInput,
                            onCitationTapped: { sec in
                                currentTab = 0
                                manager.playAudio(session: activeSession, seekTo: sec)
                            }
                        )
                    }
                }

                // 底部控制条：若正在录音，展示暂停/继续/标重点/结束；若已结束且在文字页，展示音频播放条
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

    var body: some View {
        ZStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // 顶部大计时
                        if isLive {
                            VStack(spacing: 6) {
                                Text(formatDuration(manager.recordingElapsed))
                                    .font(.system(size: 42, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.primary)
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(manager.isPaused ? Color.orange : Color.green)
                                        .frame(width: 8, height: 8)
                                    Text(manager.isPaused ? "已暂停录音" : "麦克风正在持续写入")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
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
                                    Button {
                                        manager.playAudio(session: session, seekTo: seg.startTime)
                                    } label: {
                                        Text(formatDuration(seg.startTime))
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .fontDesign(.monospaced)
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
                                    Spacer()
                                }
                                .padding(12)
                                .background(seg.isMarked ? Color.orange.opacity(0.08) : Color(UIColor.secondarySystemGroupedBackground))
                                .cornerRadius(12)
                                .id(seg.id)
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
                        .font(.caption)
                        .fontWeight(.bold)
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
    }

    private func formatDuration(_ sec: TimeInterval) -> String {
        let whole = Int(sec)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

// MARK: - Tab 2: 笔记页面

struct NotesTabView: View {
    @EnvironmentObject var manager: ClassroomManager
    let session: LessonSession
    @Binding var selectedStyle: NoteStyle
    @State private var copiedNotice = false

    var currentNote: LessonNote? {
        session.notes.first(where: { $0.style == selectedStyle })
    }

    var body: some View {
        VStack(spacing: 0) {
            // 样式选择胶囊
            Picker("笔记样式", selection: $selectedStyle) {
                ForEach(NoteStyle.allCases, id: \.self) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let note = currentNote {
                        Text(note.content)
                            .font(.body)
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(16)

                        HStack {
                            Button {
                                UIPasteboard.general.string = note.content
                                copiedNotice = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedNotice = false
                                }
                            } label: {
                                Label(copiedNotice ? "已复制到剪贴板！" : "复制全部笔记", systemImage: copiedNotice ? "checkmark" : "doc.on.doc")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }

                            Spacer()

                            Button {
                                manager.generateNotes(for: session, style: selectedStyle)
                            } label: {
                                Label("重新整理", systemImage: "arrow.clockwise")
                                    .font(.subheadline)
                            }
                            .disabled(manager.isGeneratingNotes)
                        }
                        .padding(.horizontal, 4)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "doc.text.below.ecg")
                                .font(.system(size: 44))
                                .foregroundColor(.secondary.opacity(0.5))
                            Text("尚未生成\(selectedStyle.title)笔记")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("智能提炼整节课堂脉络、重要公式与考点复习大纲")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Button {
                                manager.generateNotes(for: session, style: selectedStyle)
                            } label: {
                                if manager.isGeneratingNotes {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    Label("提炼课堂笔记", systemImage: "sparkles")
                                }
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.accentColor)
                            .cornerRadius(14)
                            .disabled(manager.isGeneratingNotes)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    }
                }
                .padding(16)
            }
        }
    }
}

// MARK: - Tab 3: 问答页面

struct QATabView: View {
    @EnvironmentObject var manager: ClassroomManager
    let session: LessonSession
    @Binding var inputText: String
    var onCitationTapped: (TimeInterval) -> Void

    let quickQuestions = [
        "这节课讲了哪些核心公式？",
        "老师强调了哪些考试或作业要求？",
        "总结本节课的核心结论"
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 快捷提问气泡
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

                    if session.qaPairs.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary.opacity(0.5))
                            Text("针对课堂内容的专属答疑助手")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text("输入提问或点击上方快捷词，答案将精确关联课堂时间戳")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(session.qaPairs) { pair in
                            VStack(alignment: .leading, spacing: 8) {
                                // 问
                                HStack {
                                    Spacer()
                                    Text(pair.question)
                                        .font(.subheadline)
                                        .foregroundColor(.white)
                                        .padding(12)
                                        .background(Color.accentColor)
                                        .cornerRadius(14)
                                }

                                // 答
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(pair.answer)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                        .textSelection(.enabled)

                                    if let cit = pair.citationSeconds {
                                        Button {
                                            onCitationTapped(cit)
                                        } label: {
                                            Label("跳转到课堂录音 \(formatTime(cit))", systemImage: "play.circle.fill")
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .foregroundColor(.accentColor)
                                        }
                                        .padding(.top, 4)
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(UIColor.secondarySystemGroupedBackground))
                                .cornerRadius(14)
                            }
                        }
                    }
                }
                .padding(16)
            }

            // 底部输入框
            Divider()
            HStack(spacing: 8) {
                TextField("向课堂 AI 提问...", text: $inputText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                Button {
                    let q = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !q.isEmpty {
                        manager.askQuestion(for: session, query: q)
                        inputText = ""
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.accentColor)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.isAskingQA)
            }
            .padding(12)
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
        VStack(spacing: 6) {
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
                                .font(.caption2)
                                .fontWeight(manager.playbackRate == rate ? .bold : .regular)
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
            .font(.caption2)
            .fontWeight(.semibold)
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
