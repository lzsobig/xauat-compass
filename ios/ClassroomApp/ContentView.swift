import PhotosUI
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
        TabView(selection: $selectedTab) {
            RecordHomeView(
                selectedCourse: $selectedCourseForRecord,
                showingCoursePicker: $showingCoursePicker,
                onOpenSession: { session in selectedSession = session }
            )
            .safeAreaInset(edge: .bottom, spacing: 0) { recordingShortcut }
            .tabItem {
                Label("录音", systemImage: "mic.fill")
            }
            .tag(0)

            CourseArchiveView(
                onOpenSession: { session in selectedSession = session }
            )
            .safeAreaInset(edge: .bottom, spacing: 0) { recordingShortcut }
            .tabItem {
                Label("课程", systemImage: "folder.fill")
            }
            .tag(1)

            TimetableScreen(onSelectCourseForRecord: { course in
                guard !manager.isRecording else { return }
                selectedCourseForRecord = course
                selectedTab = 0
            })
            .safeAreaInset(edge: .bottom, spacing: 0) { recordingShortcut }
            .tabItem {
                Label("课表", systemImage: "calendar")
            }
            .tag(2)

            SettingsScreen()
            .safeAreaInset(edge: .bottom, spacing: 0) { recordingShortcut }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
            }
            .tag(3)
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

    @ViewBuilder
    private var recordingShortcut: some View {
        if manager.isRecording, let current = manager.currentSession, selectedSession == nil {
            Button {
                selectedSession = current
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(manager.isPaused ? Color.orange : Color.red)
                        .frame(width: 8, height: 8)
                    Text(manager.isPaused ? "录音已暂停" : "正在录音")
                    Text(formatTime(manager.recordingElapsed))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("返回录音")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(UIColor.secondarySystemGroupedBackground))
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
    @State private var showASRKeyPrompt = false
    @State private var showASRSettings = false

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

                        Menu {
                            Picker("转写引擎", selection: Binding(get: { manager.asrProvider }, set: { manager.selectASRProvider($0) })) {
                                ForEach(CloudTranscriptionProvider.allCases) { provider in
                                    Text(provider.title).tag(provider)
                                }
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Label(manager.asrProvider.title, systemImage: "waveform")
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.semibold))
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 11)
                            .frame(minHeight: 44)
                            .background(Color(UIColor.tertiarySystemFill), in: Capsule())
                        }
                        .accessibilityLabel("转写引擎")
                        .accessibilityValue(manager.asrProvider.title)
                        .disabled(manager.isRecording)

                        HStack(spacing: 12) {
                            Button {
                                Task {
                                    guard manager.hasActiveASRKey else {
                                        showASRKeyPrompt = true
                                        return
                                    }
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
        .alert("实时转写需要 API Key", isPresented: $showASRKeyPrompt) {
            Button("去设置") { showASRSettings = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前引擎为\(manager.asrProvider.title)。请填写对应 Key 后再开始实时转写。")
        }
        .sheet(isPresented: $showASRSettings) {
            SettingsScreen().environmentObject(manager)
        }
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

    private var courseListSection: some View {
        Section("课表与课程库") {
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
    }

    private var unassignedSection: some View {
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
    }

    private var addCourseSection: some View {
        Section {
            Button {
                showingAddAlert = true
            } label: {
                Label("新建课程分类", systemImage: "plus")
            }
        }
    }

    var body: some View {
        NavigationView {
            List {
                courseListSection
                unassignedSection
                addCourseSection
            }
            .navigationTitle("选择课程")
            .navigationBarItems(trailing: Button("完成") { presentationMode.wrappedValue.dismiss() })
            .alert("新建课程", isPresented: $showingAddAlert) {
                TextField("课程名称", text: $newCourseName)
                Button("取消", role: .cancel) { newCourseName = "" }
                Button("创建") {
                    let trim = newCourseName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trim.isEmpty {
                        manager.createCourse(name: trim)
                        selectedCourse = manager.courses.last
                        newCourseName = ""
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
    @State private var coursePendingDelete: Course? = nil
    @State private var showDeleteConfirmation = false
    @State private var showAddCourseSheet = false
    @State private var newCourseName = ""
    @State private var newCourseTeacher = ""
    @State private var newCourseRoom = ""
    var onOpenSession: (LessonSession) -> Void

    var filteredCourses: [Course] {
        if searchText.isEmpty { return manager.courses }
        return manager.courses.filter { c in
            c.name.localizedCaseInsensitiveContains(searchText) ||
            c.teacher.localizedCaseInsensitiveContains(searchText) ||
            manager.sessions.contains(where: { $0.courseId == c.id && ($0.title.localizedCaseInsensitiveContains(searchText) || $0.fullTranscript.localizedCaseInsensitiveContains(searchText)) })
        }
    }

    var activeTimetableCourses: [Course] {
        filteredCourses.filter { $0.source == .timetable && $0.status == .active }
    }

    var manualCourses: [Course] {
        filteredCourses.filter { $0.source == .manual }
    }

    var historicalCourses: [Course] {
        filteredCourses.filter { $0.status == .historical }
    }

    var unassignedSessions: [LessonSession] {
        manager.sessions.filter { $0.courseId == nil }
    }

    private var searchHeaderSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索课程、教师、转写内容...", text: $searchText)
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
    }

    @ViewBuilder
    private var activeSection: some View {
        if !activeTimetableCourses.isEmpty {
            Section(
                header: Text("当前课表课程 (\(activeTimetableCourses.count))"),
                footer: Text("由当前学期课表自动关联")
            ) {
                ForEach(activeTimetableCourses) { c in
                    courseRow(c)
                }
            }
        }
    }

    @ViewBuilder
    private var manualSection: some View {
        if !manualCourses.isEmpty {
            Section(
                header: Text("自建与拓展课程 (\(manualCourses.count))"),
                footer: Text("手动创建的课程，不受课表变动影响")
            ) {
                ForEach(manualCourses) { c in
                    courseRow(c)
                }
            }
        }
    }

    @ViewBuilder
    private var historicalSection: some View {
        if !historicalCourses.isEmpty {
            Section(
                header: Text("历史课程 (\(historicalCourses.count))"),
                footer: Text("不在当前课表中，但保留全部课堂录音与资料")
            ) {
                ForEach(historicalCourses) { c in
                    courseRow(c)
                }
            }
        }
    }

    private var unassignedSection: some View {
        Section(header: Text("未归档资料")) {
            NavigationLink {
                UnassignedDetailScreen(onOpenSession: onOpenSession)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "tray.fill")
                        .foregroundColor(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("未归档课堂记录")
                            .font(.headline)
                        Text("未关联到具体课程或已解绑文件夹的录音")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("\(unassignedSessions.count) 节课")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    var body: some View {
        NavigationView {
            List {
                searchHeaderSection
                activeSection
                manualSection
                historicalSection
                unassignedSection
            }
            .navigationTitle("课程资料库")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            newCourseName = ""
                            newCourseTeacher = ""
                            newCourseRoom = ""
                            showAddCourseSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .bold))
                        }

                        Menu {
                            Button {
                                manager.syncCoursesFromTimetable()
                            } label: {
                                Label("从当前课表同步课程", systemImage: "arrow.triangle.2.circlepath")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 16))
                        }
                    }
                }
            }
            .confirmationDialog(
                "删除课程文件夹「\(coursePendingDelete?.name ?? "")」",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("仅移除课程文件夹 (保留所有录音至未归档)") {
                    if let c = coursePendingDelete {
                        manager.deleteCourse(course: c, purgeAllData: false)
                        coursePendingDelete = nil
                    }
                }
                Button("彻底删除课程及全部资料 (包含录音文件)", role: .destructive) {
                    if let c = coursePendingDelete {
                        manager.deleteCourse(course: c, purgeAllData: true)
                        coursePendingDelete = nil
                    }
                }
                Button("取消", role: .cancel) {
                    coursePendingDelete = nil
                }
            } message: {
                Text("移至未归档可随时在「未归档」分类中继续查看和播放录音与笔记。彻底删除将永久清除该课程及其名下全部录音和文件。")
            }
            .sheet(isPresented: $showAddCourseSheet) {
                NavigationView {
                    Form {
                        Section("课程基本信息") {
                            TextField("课程名称 (如: 线性代数)", text: $newCourseName)
                            TextField("任课教师 (可选)", text: $newCourseTeacher)
                            TextField("上课教室 (可选)", text: $newCourseRoom)
                        }
                    }
                    .navigationTitle("新建自建课程")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("取消") { showAddCourseSheet = false }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("创建") {
                                let trimmed = newCourseName.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty else { return }
                                let newC = Course(
                                    name: trimmed,
                                    teacher: newCourseTeacher.trimmingCharacters(in: .whitespacesAndNewlines),
                                    room: newCourseRoom.trimmingCharacters(in: .whitespacesAndNewlines),
                                    source: .manual,
                                    status: .active
                                )
                                manager.courses.append(newC)
                                manager.saveCourses()
                                showAddCourseSheet = false
                            }
                            .disabled(newCourseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    @ViewBuilder
    private func courseRow(_ c: Course) -> some View {
        let count = manager.sessions.filter { $0.courseId == c.id }.count
        NavigationLink {
            CourseDetailScreen(course: c, onOpenSession: onOpenSession)
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: c.colorHex))
                    .frame(width: 14, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(c.name)
                            .font(.headline)
                        if c.source == .manual {
                            Text("自建")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(3)
                        }
                    }
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
        .contextMenu {
            Button(role: .destructive) {
                coursePendingDelete = c
                showDeleteConfirmation = true
            } label: {
                Label("删除课程文件夹...", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                coursePendingDelete = c
                showDeleteConfirmation = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

struct CourseDetailScreen: View {
    @EnvironmentObject var manager: ClassroomManager
    @Environment(\.presentationMode) var presentationMode
    let course: Course
    var onOpenSession: (LessonSession) -> Void
    @State private var sessionToMove: LessonSession?
    @State private var sessionToRename: LessonSession?
    @State private var newTitle = ""
    @State private var showDeleteConfirm = false

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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
        }
        .alert("确认删除课程文件夹？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                manager.deleteCourse(course: course)
                presentationMode.wrappedValue.dismiss()
            }
        } message: {
            Text("删除后，该课程下的录音记录将安全移入【未归档】，录音文件与笔记不会丢失。")
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

// MARK: - 单周课表渲染组件 (支持左右滑动换周)

struct WeekGridView: View {
    let week: Int
    let timetable: TimetableData
    let dayColWidth: CGFloat
    let timeColWidth: CGFloat
    let slotHeight: CGFloat
    let totalGridHeight: CGFloat
    var onSlotTap: (TimetableSlot) -> Void

    let days = ["一", "二", "三", "四", "五", "六", "日"]

    var weekDates: [Date] {
        SemesterCalendar.datesForWeek(week)
    }

    var monthNumber: Int {
        guard let first = weekDates.first else { return 11 }
        return Calendar(identifier: .gregorian).component(.month, from: first)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 1. 顶部日期表头
            HStack(spacing: 0) {
                VStack(spacing: 1) {
                    Text("\(monthNumber)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                    Text("月")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .frame(width: timeColWidth, height: 46)

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
                    let activeSlots = timetable.slots.filter { slot in
                        week >= slot.weekFrom &&
                        week <= slot.weekTo &&
                        (slot.parity == "all" || (slot.parity == "odd" && week % 2 == 1) || (slot.parity == "even" && week % 2 == 0))
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
                                onSlotTap(slot)
                            }
                        }
                    }
                }
                .frame(width: (timeColWidth + dayColWidth * 7.0), height: totalGridHeight)
            }
        }
    }
}

struct TimetableScreen: View {
    @EnvironmentObject var manager: ClassroomManager
    var onSelectCourseForRecord: ((Course) -> Void)? = nil

    @State private var selectedWeek: Int = 10
    @State private var showingFileImporter = false
    @State private var importStatus = ""
    @State private var selectedSlotForDetail: TimetableSlot?
    @State private var pendingImportDraft: TimetableImportDraft? = nil

    let timeColWidth: CGFloat = 34.0
    let slotHeight: CGFloat = 58.0

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

                    // 左右滑动翻周核心 TabView 分页容器
                    TabView(selection: $selectedWeek) {
                        ForEach(1...20, id: \.self) { w in
                            WeekGridView(
                                week: w,
                                timetable: manager.timetable,
                                dayColWidth: dayColWidth,
                                timeColWidth: timeColWidth,
                                slotHeight: slotHeight,
                                totalGridHeight: totalGridHeight,
                                onSlotTap: { slot in
                                    selectedSlotForDetail = slot
                                }
                            )
                            .tag(w)
                        }
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                    .onChange(of: selectedWeek) { newWeek in
                        manager.timetable.currentWeek = newWeek
                        manager.saveTimetable()
                        manager.updateCourseSuggestion()
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 2) {
                        Button {
                            if selectedWeek > 1 {
                                withAnimation { selectedWeek -= 1 }
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(selectedWeek > 1 ? .primary : .secondary.opacity(0.3))
                                .padding(6)
                        }
                        .disabled(selectedWeek <= 1)

                        Menu {
                            ForEach(1...20, id: \.self) { w in
                                Button {
                                    withAnimation { selectedWeek = w }
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

                        Button {
                            if selectedWeek < 20 {
                                withAnimation { selectedWeek += 1 }
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(selectedWeek < 20 ? .primary : .secondary.opacity(0.3))
                                .padding(6)
                        }
                        .disabled(selectedWeek >= 20)
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
                            let draft = try manager.parseTimetableDraft(data: data)
                            let reconciled = manager.reconcileCourses(draft: draft)
                            pendingImportDraft = reconciled
                        } catch {
                            importStatus = "导入解析失败：\(error.localizedDescription)"
                        }
                    }
                case .failure(let err):
                    importStatus = "读取文件失败：\(err.localizedDescription)"
                }
            }
            .sheet(isPresented: Binding(
                get: { pendingImportDraft != nil },
                set: { if !$0 { pendingImportDraft = nil } }
            )) {
                if let draft = pendingImportDraft {
                    TimetableImportPreviewSheet(
                        draft: draft,
                        onConfirm: { finalDraft in
                            guard manager.commitTimetableImport(draft: finalDraft) else {
                                importStatus = manager.errorMessage
                                return
                            }
                            selectedWeek = manager.timetable.currentWeek > 0 ? manager.timetable.currentWeek : SemesterCalendar.currentWeek()
                            importStatus = "课表导入成功！共导入 \(finalDraft.items.filter { $0.isSelected }.count) 门课程，\(finalDraft.slots.count) 个课程节次"
                            pendingImportDraft = nil
                        },
                        onCancel: {
                            pendingImportDraft = nil
                        }
                    )
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

                Section(header: Text("语音转写密钥"),
                        footer: Text("转写服务统一在首页选择，录音期间保持不变")) {
                    SecureField("硅基流动 API Key", text: $manager.siliconFlowApiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("阶跃 API Key", text: $manager.stepFunApiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
                        Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
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

// MARK: - TXT 导出与原生分享组件

struct ShareItem: Identifiable {
    let id = UUID()
    let fileURL: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

func createTempTXT(filename: String, content: String) -> URL? {
    let tempDir = FileManager.default.temporaryDirectory
    let safeName = filename.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined(separator: "_")
    let fileURL = tempDir.appendingPathComponent("\(safeName).txt")
    do {
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    } catch {
        return nil
    }
}

struct LessonDetailView: View {
    @EnvironmentObject var manager: ClassroomManager
    @Environment(\.presentationMode) var presentationMode
    let session: LessonSession
    @State private var currentTab: Int = 0 // 0: 实录，1: 问答
    @State private var selectedNoteStyle: NoteStyle = .minutes
    @State private var showMinutes = false
    @State private var showExport = false
    @State private var qaInput = ""
    @State private var followBottom = true
    @State private var unreadSegmentCount = 0
    @State private var showRenameAlert = false
    @State private var editTitle = ""
    @State private var shareItem: ShareItem? = nil

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
                        Label(manager.isPaused ? "已暂停" : (activeSession.mode == .realtime ? manager.asrProvider.title : "仅录音"), systemImage: "waveform")
                            .font(.caption)

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
                        title: "实录",
                        systemImage: "waveform",
                        isSelected: currentTab == 0,
                        badge: activeSession.segments.count > 0 ? "\(activeSession.segments.count)" : nil
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            currentTab = 0
                        }
                    }

                    DetailTabPill(
                        title: "问答",
                        systemImage: "sparkles",
                        isSelected: currentTab == 1,
                        badge: activeSession.qaPairs.count > 0 ? "\(activeSession.qaPairs.count)" : nil
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            currentTab = 1
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
                            withAnimation { currentTab = 1 }
                        },
                        onSwitchToTab: { tab in
                            withAnimation { currentTab = tab }
                        },
                        onShowMinutes: {
                            selectedNoteStyle = .minutes
                            showMinutes = true
                        }
                    )
                    .tag(0)

                    QATabView(
                        session: activeSession,
                        inputText: $qaInput,
                        selectedNoteStyle: $selectedNoteStyle,
                        onCitationTapped: { sec in
                            withAnimation { currentTab = 0 }
                            manager.playAudio(session: activeSession, seekTo: sec)
                        }
                    )
                    .tag(1)
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))

                // 底部录音控制栏或播放条
                if isLiveActive {
                    LiveRecordingControlBar(session: activeSession) {
                        presentationMode.wrappedValue.dismiss()
                    }
                } else if currentTab == 0 {
                    AudioPlayerControlBar(session: activeSession)
                }
            }
            .sheet(isPresented: $showMinutes) {
                NavigationView {
                    NotesTabView(session: activeSession, selectedStyle: $selectedNoteStyle,
                                 onSwitchToQA: { showMinutes = false; currentTab = 1 })
                        .navigationTitle("课堂纪要")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showMinutes = false }
                            }
                        }
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
                    HStack(spacing: 12) {
                        Button { showExport = true } label: {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("导出课堂")

                        Button("完成") {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $showExport) { ClassroomExportSheet(session: activeSession) }
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.fileURL])
        }
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
    var onShowMinutes: (() -> Void)? = nil

    @State private var selectedSegmentForQA: TranscriptSegment?
    @State private var isSelectMode: Bool = false
    @State private var selectedIds: Set<UUID> = []
    @State private var toastMessage: String? = nil
    @State private var shareItem: ShareItem? = nil

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 1. 断网或分片待补转写横幅（支持一键断网重试补转）
                if !isLive && (session.status == .pendingCatchUp || session.status == .transcriptionFailed || session.chunkTasks.contains { $0.status == .pending || $0.status == .failed }) {
                    let pendingCount = session.chunkTasks.filter { $0.status == .pending || $0.status == .failed }.count
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("因网络波动，尚有 \(max(1, pendingCount)) 个分片待补转写")
                                .font(.caption.bold())
                                .foregroundColor(.primary)
                            Text("原始音频已安全缓存在本地，连网后点击即可补转")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            manager.retryPendingChunks(for: session)
                        } label: {
                            HStack(spacing: 4) {
                                if manager.isChunkTranscribing {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text("一键补转写")
                                    .font(.caption.bold())
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .disabled(manager.isChunkTranscribing)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.12))
                } else if !isLive && session.isTempAudioPurged {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12))
                        Text("全部分片已完整转写，临时录音已自动清理（已释放手机存储）")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.08))
                }

                if !isLive {
                    HStack {
                        Button { onShowMinutes?() } label: {
                            Label("查看纪要", systemImage: "doc.text")
                                .font(.subheadline.weight(.medium))
                        }
                        Spacer()
                        if manager.isGeneratingNotes { ProgressView().scaleEffect(0.8) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
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
                            // 1. 全选复制全部实录文字
                            Button {
                                let allText = session.segments
                                    .sorted { $0.startTime < $1.startTime }
                                    .map { "[\(formatDuration($0.startTime))] \($0.text)" }
                                    .joined(separator: "\n\n")
                                UIPasteboard.general.string = allText
                                toastMessage = "已全选复制全部 \(session.segments.count) 段实录"
                            } label: {
                                Label("全选复制", systemImage: "doc.on.doc")
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color(UIColor.tertiarySystemFill))
                                    .cornerRadius(8)
                            }

                            // 2. 导出为 TXT 文档
                            Button {
                                let header = """
========================================
【课堂语音实录】
课程：\(session.courseName)
主题：\(session.title)
录音时长：\(formatDuration(session.duration))
实录分段：共 \(session.segments.count) 段
========================================

"""
                                let body = session.segments
                                    .sorted { $0.startTime < $1.startTime }
                                    .map { "[\(formatDuration($0.startTime))] \($0.text)" }
                                    .joined(separator: "\n\n")
                                let name = "\(session.title)-语音实录"
                                if let url = createTempTXT(filename: name, content: header + body) {
                                    shareItem = ShareItem(fileURL: url)
                                }
                            } label: {
                                Label("导出 TXT", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color(UIColor.tertiarySystemFill))
                                    .cornerRadius(8)
                            }

                            Spacer()

                            // 3. 多选模式
                            Button {
                                isSelectMode = true
                            } label: {
                                Label("多选", systemImage: "checklist")
                                    .font(.system(size: 12, weight: .medium))
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
                                Label(manager.isPaused ? "已暂停" : "录音中", systemImage: "waveform")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(16)
                        }

                        if isLive && session.mode == .realtime,
                           let failed = session.chunkTasks.last(where: { $0.status == .failed }) {
                            Label("转写分段失败，录音仍在保存。可在结束后补转写。", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .accessibilityHint(failed.lastError ?? "")
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
                                TranscriptAttachmentImages(session: session, segment: nil, orphanBefore: seg.startTime)
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
                                        TranscriptAttachmentImages(session: session, segment: seg)
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
                                        TranscriptAttachmentControl(session: session, segment: seg)
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
                        if isLive {
                            HStack {
                                Text(session.chunkTasks.contains(where: { $0.status == .pending || $0.status == .transcribing }) ? "正在转写" : "当前录音")
                                    .font(.subheadline).foregroundColor(.secondary)
                                Spacer()
                                TranscriptAttachmentControl(session: session, segment: nil)
                            }
                        }

                        TranscriptAttachmentImages(session: session, segment: nil)
                        Color.clear.frame(height: 1).id("transcript-bottom")
                    }
                    .padding(16)
                }
                .onChange(of: session.segments.count) { _ in
                    if followBottom {
                        withAnimation {
                            proxy.scrollTo("transcript-bottom", anchor: .bottom)
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
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.fileURL])
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
    @State private var editing = false
    @State private var draftContent = ""
    @State private var editError = ""
    @State private var shareItem: ShareItem? = nil

    var currentNote: LessonNote? {
        session.notes.first(where: { $0.style == selectedStyle })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = session.minutesGenerationError {
                        Text(error).font(.caption).foregroundColor(.red)
                    }
                    HStack {
                        Menu {
                            ForEach(NoteStyle.allCases, id: \.self) { style in
                                Button(style.title) { selectedStyle = style }
                            }
                        } label: { Label(selectedStyle.title, systemImage: "doc.text") }
                        Spacer()
                        Button {
                            draftContent = currentNote?.content ?? ""
                            editError = ""
                            editing = true
                        } label: { Label("编辑", systemImage: "pencil") }
                    }
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
                        // 笔记卡片头部与风格切换
                        HStack {
                            Label(selectedStyle.title, systemImage: "doc.text.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.primary)

                            Spacer()

                            Menu {
                                ForEach(NoteStyle.allCases, id: \.self) { style in
                                    Button {
                                        selectedStyle = style
                                        if !session.notes.contains(where: { $0.style == style }) {
                                            manager.generateNotes(for: session, style: style)
                                        }
                                    } label: {
                                        if selectedStyle == style {
                                            Label(style.title, systemImage: "checkmark")
                                        } else if session.notes.contains(where: { $0.style == style }) {
                                            Label(style.title, systemImage: "doc.text")
                                        } else {
                                            Text(style.title + " (点击生成)")
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("切换/生成其他风格")
                                    Image(systemName: "chevron.up.chevron.down")
                                }
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(UIColor.tertiarySystemFill))
                                .foregroundColor(.primary)
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 4)

                        MarkdownContentView(content: note.content) { time in
                            guard time <= session.duration else { return }
                            manager.playAudio(session: session, seekTo: time)
                        }
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
                                Label(copiedNotice ? "已复制！" : "全选复制", systemImage: copiedNotice ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color(UIColor.tertiarySystemFill))
                                    .foregroundColor(.primary)
                                    .cornerRadius(10)
                            }

                            Button {
                                let name = "\(session.title)-\(selectedStyle.title)"
                                let header = """
========================================
【智能课堂笔记 - \(selectedStyle.title)】
课程：\(session.courseName)
主题：\(session.title)
整理：DeepSeek AI
========================================

"""
                                if let url = createTempTXT(filename: name, content: header + note.content) {
                                    shareItem = ShareItem(fileURL: url)
                                }
                            } label: {
                                Label("导出 TXT", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 12)
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
                        // 空白初始状态：移除顶部重复按钮，仅保留 3 大专业卡片
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
                                    title: "课堂纪要",
                                    subtitle: "课堂内容、重点、作业与提醒",
                                    icon: "doc.text",
                                    accentColor: .blue
                                ) {
                                    selectedStyle = .minutes
                                    manager.generateNotes(for: session, style: .minutes)
                                }
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
            .sheet(isPresented: $editing) {
                NavigationView {
                    VStack {
                        TextEditor(text: $draftContent).padding()
                        if !editError.isEmpty { Text(editError).foregroundColor(.red).font(.caption) }
                    }
                    .navigationTitle("编辑" + selectedStyle.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { editing = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                do {
                                    try manager.saveNoteContent(sessionId: session.id, style: selectedStyle, content: draftContent)
                                    editing = false
                                } catch { editError = "保存失败：\(error.localizedDescription)" }
                            }
                        }
                    }
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(activityItems: [item.fileURL])
            }
        }
    }
}


// MARK: - Tab 3: 问答页面

struct QATabView: View {
    @EnvironmentObject var manager: ClassroomManager
    let session: LessonSession
    @Binding var inputText: String
    @Binding var selectedNoteStyle: NoteStyle
    var onCitationTapped: (TimeInterval) -> Void

    @FocusState private var composing: Bool
    @State private var showNotes = false
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var cameraError = false
    @State private var pendingQuestion: String?
    @State private var pendingImage: Data?
    @State private var waitingSince: Date?
    @State private var photo: UIImage?
    @State private var photoError = false
    @State private var recentScope: Bool?

    private var usesRecentScope: Bool {
        recentScope ?? (manager.isRecording && manager.currentSession?.id == session.id)
    }
    @State private var showMinutesError = false

    private let prompts = [
        ("整理提纲", "按课堂顺序整理这节课的提纲，列出关键概念和推导。"),
        ("核心公式", "整理这节课的核心公式，解释符号和适用条件。"),
        ("作业与考点", "整理老师明确提到的作业、实验要求与考试重点。")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if session.qaPairs.isEmpty && !manager.isAskingQA {
                            Label("想问点什么？", systemImage: "sparkles")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 52)
                        }
                        ForEach(session.qaPairs) { pair in
                            VStack(alignment: .leading, spacing: 12) {
                                questionBubble(pair.question, imageJPEG: pair.imageJPEG)
                                Label("课堂助教", systemImage: "sparkles")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 7)
                                MarkdownContentView(content: pair.answer) { time in
                                    guard time <= session.duration else { return }
                                    onCitationTapped(time)
                                }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if pair.scope == "recent" {
                                    Button("用整节课重答") {
                                        recentScope = false
                                        pendingQuestion = pair.originalQuery ?? pair.question
                                        pendingImage = pair.imageJPEG
                                        waitingSince = Date()
                                        manager.askQuestion(for: session, query: pair.originalQuery ?? pair.question, imageJPEG: pair.imageJPEG)
                                    }
                                    .font(.caption)
                                    .disabled(manager.isAskingQA)
                                }
                                Button {
                                    UIPasteboard.general.string = pair.answer
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .frame(width: 44, height: 36)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("复制回答")
                                if let seconds = pair.citationSeconds {
                                    Button {
                                        composing = false
                                        onCitationTapped(seconds)
                                    } label: {
                                        Label("跳到 \(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))", systemImage: "play.circle")
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                        if manager.answeringSessionID == session.id {
                            if let pendingQuestion { questionBubble(pendingQuestion, imageJPEG: pendingImage) }
                            if !manager.streamingAnswer.isEmpty {
                                MarkdownContentView(content: manager.streamingAnswer)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            HStack(spacing: 10) {
                                ProgressView()
                                    .tint(.accentColor)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(manager.streamingAnswer.isEmpty ? "正在整理回答" : "正在输出")
                                        .font(.subheadline.weight(.medium))
                                    if manager.streamingAnswer.isEmpty, let waitingSince {
                                        TimelineView(.periodic(from: waitingSince, by: 1)) { context in
                                            Text("已等待 \(max(0, Int(context.date.timeIntervalSince(waitingSince)))) 秒")
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 13))
                            .transition(.opacity.combined(with: .offset(y: 4)))
                        }
                        Color.clear.frame(height: 1).id("answer-bottom")
                    }
                    .padding(16)
                    .animation(.easeInOut(duration: 0.2), value: manager.isAskingQA)
                }
                .modifier(AnswerKeyboardDismiss(focused: $composing))
                .onChange(of: manager.isAskingQA) { active in
                    if active {
                        waitingSince = Date()
                    } else {
                        pendingQuestion = nil
                        pendingImage = nil
                        waitingSince = nil
                    }
                    withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo("answer-bottom", anchor: .bottom) }
                }
                .onChange(of: session.qaPairs.count) { _ in
                    withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo("answer-bottom", anchor: .bottom) }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Menu {
                    Button("最近 3 分钟") { recentScope = true }
                    Button("整节课") { recentScope = false }
                } label: {
                    Label(usesRecentScope ? "最近 3 分钟" : "整节课", systemImage: "chevron.down")
                        .font(.footnote)
                }
                if usesRecentScope && manager.currentSession?.id == session.id && manager.isChunkTranscribing {
                    Text("最新一段正在转写").font(.caption).foregroundStyle(.secondary)
                }
                if let photo {
                    HStack(spacing: 8) {
                        Image(uiImage: photo).resizable().scaledToFill()
                            .frame(width: 48, height: 42).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        Button {
                            withAnimation { self.photo = nil }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .accessibilityLabel("移除图片")
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
                HStack(spacing: 10) {
                    Menu {
                        Button {
                            composing = false
                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                showCamera = true
                            } else {
                                cameraError = true
                            }
                        } label: { Label("拍照", systemImage: "camera") }
                        Button {
                            composing = false
                            showPhotos = true
                        } label: { Label("从相册选取", systemImage: "photo.on.rectangle") }
                    } label: {
                        Image(systemName: "paperclip").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("添加图片")
                    TextField("问这节课", text: $inputText)
                        .focused($composing)
                        .submitLabel(.send)
                        .onSubmit(send)
                    if composing {
                        Button { composing = false } label: {
                            Image(systemName: "keyboard.chevron.compact.down").frame(width: 34, height: 42)
                        }
                        .accessibilityLabel("收起键盘")
                    }
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .frame(width: 42, height: 42)
                    }
                    .accessibilityLabel("发送")
                    .disabled((inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photo == nil) || manager.isAskingQA)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 19))
            .overlay {
                RoundedRectangle(cornerRadius: 19)
                    .strokeBorder(
                        composing ? Color.accentColor : Color(UIColor.opaqueSeparator),
                        lineWidth: composing ? 1.6 : 1
                    )
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.16), value: composing)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .sheet(isPresented: $showNotes) {
            NavigationView {
                NotesTabView(session: manager.sessions.first(where: { $0.id == session.id }) ?? session,
                             selectedStyle: $selectedNoteStyle, onSwitchToQA: { showNotes = false })
                    .safeAreaInset(edge: .bottom) {
                        if selectedNoteStyle == .minutes && !manager.isGeneratingNotes && !manager.errorMessage.isEmpty {
                            Text(manager.errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(10)
                        }
                    }
                    .navigationTitle("课堂笔记")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showNotes = false }
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            ClassroomCamera { image in
                showCamera = false
                if let image { withAnimation { photo = image } }
            }
            .ignoresSafeArea()
        }
        .alert("相机不可用", isPresented: $cameraError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请检查系统相机权限，也可以从相册选取图片。")
        }
        .sheet(isPresented: $showPhotos) {
            ClassroomPhotoPicker { result in
                showPhotos = false
                switch result {
                case .success(let image): withAnimation { photo = image }
                case .failure: photoError = true
                }
            } onCancel: {
                showPhotos = false
            }
        }
        .alert("无法生成纪要", isPresented: $showMinutesError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(manager.errorMessage)
        }
        .alert("无法读取这张图片", isPresented: $photoError) {
            Button("好", role: .cancel) {}
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            composing = false
        }
    }

    private func questionBubble(_ question: String, imageJPEG: Data?) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let imageJPEG, let image = UIImage(data: imageJPEG) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 180, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                    .accessibilityLabel("提问附件图片")
            }
            Text(question)
                .font(.subheadline)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.leading, 40)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func send() {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !manager.isAskingQA, !query.isEmpty || photo != nil else { return }
        if usesRecentScope && photo == nil && manager.recentQuestionSegments(for: session).isEmpty {
            manager.errorMessage = "最近 3 分钟还没有可用转写"
            return
        }
        var jpeg: Data?
        if let photo {
            let scale = min(1, 1600 / max(photo.size.width, photo.size.height))
            let size = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                photo.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let data = image.jpegData(compressionQuality: 0.8) else {
                photoError = true
                return
            }
            jpeg = data
        }
        let message = query.isEmpty ? "请解释这张图片里的内容。" : query
        pendingQuestion = message
        pendingImage = jpeg
        waitingSince = Date()
        manager.askQuestion(for: session, query: message, imageJPEG: jpeg, recentOnly: usesRecentScope)
        composing = false
        withAnimation { photo = nil; inputText = "" }
    }
}

private struct TranscriptAttachmentControl: View {
    @EnvironmentObject var manager: ClassroomManager
    let session: LessonSession
    let segment: TranscriptSegment?
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var choosingSource = false
    @State private var insertionTime: TimeInterval = 0

    private func freezeTime() {
        insertionTime = segment?.startTime ?? manager.currentRecordingTime
    }

    var body: some View {
        Button {
            freezeTime()
            choosingSource = true
        } label: {
            Image(systemName: "photo.badge.plus")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("在这段实录下插入图片")
        .confirmationDialog("插入课件图", isPresented: $choosingSource, titleVisibility: .visible) {
            Button("从相册添加") { showLibrary = true }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("拍摄课件") { showCamera = true }
            }
            Button("取消", role: .cancel) { }
        }
        .sheet(isPresented: $showLibrary) {
            ClassroomPhotoPicker { result in
                showLibrary = false
                switch result {
                case .success(let image): save(image)
                case .failure(let error): manager.errorMessage = "读取图片失败：\(error.localizedDescription)"
                }
            } onCancel: { showLibrary = false }
        }
        .sheet(isPresented: $showCamera) {
            ClassroomCamera { image in
                showCamera = false
                if let image { save(image) }
            }
        }
    }

    private func save(_ image: UIImage) {
        let scale = min(1, 2400 / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else {
            manager.errorMessage = "图片编码失败，请重新选择"
            return
        }
        do {
            try manager.addAttachment(sessionId: session.id, time: insertionTime, segmentId: segment?.id, jpeg: jpeg)
        } catch { manager.errorMessage = "保存课件图失败：\(error.localizedDescription)" }
    }
}

private struct TranscriptAttachmentImages: View {
    @EnvironmentObject var manager: ClassroomManager
    let session: LessonSession
    let segment: TranscriptSegment?
    var orphanBefore: TimeInterval? = nil
    @State private var removing: LessonAttachment?

    private func formatDuration(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var attachments: [LessonAttachment] {
        session.attachments.filter { attachment in
            guard attachment.resolvedSegment(in: session.segments) == segment?.id else { return false }
            if segment != nil { return true }
            let upper = orphanBefore ?? .infinity
            let lower = session.segments.map(\.startTime).filter { $0 < upper }.max() ?? 0
            return attachment.time >= lower && attachment.time < upper
        }.sorted { $0.time < $1.time }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(attachments) { attachment in
                VStack(alignment: .leading, spacing: 6) {
                    if let image = UIImage(contentsOfFile: manager.attachmentURL(attachment).path) {
                        Image(uiImage: image).resizable().scaledToFit().cornerRadius(10)
                            .accessibilityLabel("课件图，\(formatDuration(attachment.time))")
                    } else {
                        Label("课件图文件缺失", systemImage: "photo")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Button {
                            manager.playAudio(session: session, seekTo: attachment.time)
                        } label: { Label(formatDuration(attachment.time), systemImage: "play.circle") }
                        Spacer()
                        Button(role: .destructive) { removing = attachment } label: {
                            Image(systemName: "trash").frame(width: 44, height: 44)
                        }.accessibilityLabel("移除课件图")
                    }.font(.caption)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: attachments.map { $0.id })
        .alert("移除这张课件图？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("取消", role: .cancel) { removing = nil }
            Button("移除", role: .destructive) {
                guard let attachment = removing else { return }
                do { try manager.removeAttachment(sessionId: session.id, attachment: attachment) }
                catch { manager.errorMessage = "移除图片失败：\(error.localizedDescription)" }
                removing = nil
            }
        }
    }
}

private struct ClassroomCamera: UIViewControllerRepresentable {
    var onResult: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onResult: (UIImage?) -> Void

        init(onResult: @escaping (UIImage?) -> Void) { self.onResult = onResult }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onResult(nil)
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onResult(info[.originalImage] as? UIImage)
        }
    }
}

private struct AnswerKeyboardDismiss: ViewModifier {
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            content.scrollDismissesKeyboard(.interactively)
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 20).onChanged { value in
                if value.translation.height > 20 { focused.wrappedValue = false }
            })
        }
    }
}

private struct ClassroomPhotoPicker: UIViewControllerRepresentable {
    var onResult: (Result<UIImage, Error>) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ClassroomPhotoPicker
        init(parent: ClassroomPhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else { parent.onCancel(); return }
            provider.loadObject(ofClass: UIImage.self) { [parent] item, error in
                DispatchQueue.main.async {
                    if let image = item as? UIImage {
                        parent.onResult(.success(image))
                    } else {
                        parent.onResult(.failure(error ?? CocoaError(.fileReadCorruptFile)))
                    }
                }
            }
        }
    }
}

// MARK: - 底部录音控制栏

struct LiveRecordingControlBar: View {
    @EnvironmentObject var manager: ClassroomManager
    let session: LessonSession
    var onDiscard: () -> Void
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
            Button("结束并保存") {
                manager.stopRecording()
            }
            Button("结束且不保存", role: .destructive) {
                manager.stopRecording(discard: true)
                onDiscard()
            }
        } message: {
            Text("选择不保存会丢弃本次录音及其转写。")
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
        case .pendingCatchUp: return .blue
        case .transcriptionFailed: return .red
        case .interrupted: return .red
        case .completed: return .secondary
        case .recordOnlyCompleted: return .indigo
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



// MARK: - 课表导入草稿预览对照 Sheet (v1.4.0)

struct TimetableImportPreviewSheet: View {
    @State var draft: TimetableImportDraft
    var onConfirm: (TimetableImportDraft) -> Void
    var onCancel: () -> Void

    var selectedCount: Int {
        draft.items.filter { $0.isSelected }.count
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部说明卡片
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("课表导入预览与对照")
                                .font(.headline)
                            Text("已解析 \(draft.items.count) 门课程，共 \(draft.slots.count) 个课程节次")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(draft.semester)
                            .font(.caption)
                            .bold()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(UIColor.secondarySystemFill))
                            .cornerRadius(6)
                    }
                    
                    if !draft.schoolName.isEmpty || !draft.className.isEmpty {
                        Text([draft.schoolName, draft.className, draft.studentName].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Text("💡 提示：这只是预览草稿，未确认前不会修改本机课程数据。勾选需要导入的课程，可直接点击修改课程名称。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }
                .padding(14)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal)
                .padding(.top, 10)

                // 课程列表
                List {
                    Section("学期") {
                        TextField("例如 2026-2027-1", text: $draft.semester)
                            .textInputAutocapitalization(.never)
                        ForEach(draft.warnings, id: \.self) { warning in
                            Text(warning).font(.caption).foregroundColor(.orange)
                        }
                    }
                    Section(header: Text("课程对照清单 (可编辑名称或取消勾选)")) {
                        ForEach($draft.items) { $item in
                            HStack(alignment: .center, spacing: 12) {
                                Button {
                                    item.isSelected.toggle()
                                } label: {
                                    Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundColor(item.isSelected ? .accentColor : .secondary)
                                }
                                .buttonStyle(PlainButtonStyle())

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        TextField("课程名称", text: $item.editedName)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(item.isSelected ? .primary : .secondary)

                                        if item.action == .matchExisting {
                                            Text("匹配已有")
                                                .font(.system(size: 10, weight: .bold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.blue.opacity(0.12))
                                                .foregroundColor(.blue)
                                                .cornerRadius(4)
                                        } else {
                                            Text("新增课程")
                                                .font(.system(size: 10, weight: .bold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.orange.opacity(0.12))
                                                .foregroundColor(.orange)
                                                .cornerRadius(4)
                                        }
                                    }

                                    if item.deletedCourseId != nil {
                                        Toggle("恢复已删除的课程文件夹", isOn: Binding(get: {
                                            item.restoreDeletedCourse == true
                                        }, set: { item.restoreDeletedCourse = $0 }))
                                        .font(.caption)
                                    }
                                    let info = [item.teacher, item.room].filter { !$0.isEmpty }.joined(separator: " @ ")
                                    if !info.isEmpty {
                                        Text(info)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                            .opacity(item.isSelected ? 1.0 : 0.5)
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())

                // 底部操作栏
                VStack(spacing: 8) {
                    Divider()
                    HStack(spacing: 16) {
                        Button {
                            onCancel()
                        } label: {
                            Text("取消导入")
                                .font(.system(size: 15, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(UIColor.tertiarySystemFill))
                                .foregroundColor(.primary)
                                .cornerRadius(10)
                        }

                        Button {
                            onConfirm(draft)
                        } label: {
                            Text("确认导入 (\(selectedCount) 门课程)")
                                .font(.system(size: 15, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(selectedCount > 0 ? Color.accentColor : Color.gray)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .disabled(selectedCount == 0 || draft.semester.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
                .background(Color(UIColor.systemBackground))
            }
            .navigationTitle("课表导入预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("全选") {
                        for i in 0..<draft.items.count {
                            draft.items[i].isSelected = true
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
