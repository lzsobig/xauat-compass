
import re

detail_tab_pill_code = """
// MARK: - 自定义高触感 Tab 导航胶囊组件

struct DetailTabPill: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                
                if let b = badge {
                    Text(b)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.3))
                        .foregroundColor(isSelected ? .white : .primary)
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color(UIColor.tertiarySystemFill).opacity(0.5))
            .foregroundColor(isSelected ? .accentColor : .primary)
            .cornerRadius(10)
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
"""

def update_content_view(file_path):
    with open(file_path, 'r', encoding='utf-8') as f:
        text = f.read()

    # 1. Add DetailTabPill and NoteGenerationCard
    if 'struct DetailTabPill: View' not in text:
        marker = 'struct LessonDetailView: View'
        idx = text.find(marker)
        if idx != -1:
            text = text[:idx] + detail_tab_pill_code.strip() + '\n\n' + text[idx:]

    # 2. Update LessonDetailView: swipeable TabView + Custom Header
    old_ldv_body = re.search(r'struct LessonDetailView: View \{.*?
    private func formatDuration', text, re.DOTALL)
    if old_ldv_body:
        new_ldv_body = """struct LessonDetailView: View {
    @EnvironmentObject var manager: ClassroomManager
    @Environment(\\.presentationMode) var presentationMode
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
                // 自定义大触控 Tab 导航栏 (带未读/条目角标与动画)
                HStack(spacing: 6) {
                    DetailTabPill(
                        title: "实录文字",
                        systemImage: "waveform",
                        isSelected: currentTab == 0,
                        badge: activeSession.segments.count > 0 ? "\\(activeSession.segments.count)" : nil
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            currentTab = 0
                        }
                    }

                    DetailTabPill(
                        title: "课堂笔记",
                        systemImage: "note.text",
                        isSelected: currentTab == 1,
                        badge: activeSession.notes.count > 0 ? "\\(activeSession.notes.count)" : nil
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            currentTab = 1
                        }
                    }

                    DetailTabPill(
                        title: "AI 问答",
                        systemImage: "sparkles",
                        isSelected: currentTab == 2,
                        badge: activeSession.qaPairs.count > 0 ? "\\(activeSession.qaPairs.count)" : nil
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

    private func formatDuration"""
        text = text[:old_ldv_body.start()] + new_ldv_body + text[old_ldv_body.end() - len('    private func formatDuration'):]
        print(f"Updated LessonDetailView in {file_path}")

    # 3. In TranscriptTabView, add onSwitchToTab callback and bottom quick jump
    if 'var onSwitchToTab: ((Int) -> Void)? = nil' not in text:
        marker = 'var onAskAboutSegment: ((TranscriptSegment, String) -> Void)? = nil'
        text = text.replace(marker, marker + '\n    var onSwitchToTab: ((Int) -> Void)? = nil')

    # Update isLive header in TranscriptTabView to show chunk info
    old_timer_header = re.search(r'// 顶部大计时\s+if isLive \{.*?
                            \.cornerRadius\(16\)
                        \}', text, re.DOTALL)
    if old_timer_header:
        new_timer_header = """// 顶部大计时与实时模式指示
                        if isLive {
                            VStack(spacing: 8) {
                                Text(formatDuration(manager.recordingElapsed))
                                    .font(.system(size: 42, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.primary)
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(manager.isPaused ? Color.orange : (manager.transcriptionEngine == .apple ? Color.green : Color.blue))
                                        .frame(width: 8, height: 8)
                                    
                                    if manager.isPaused {
                                        Text("已暂停录音")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    } else if manager.transcriptionEngine == .apple {
                                        Text("苹果原生实时转录中 (免Key·边说边出字)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    } else {
                                        HStack(spacing: 4) {
                                            Text("阶跃星辰 ASR (\\(manager.stepfunChunkInterval.shortTitle)) 转写中")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            if manager.isChunkTranscribing {
                                                ProgressView()
                                                    .scaleEffect(0.6)
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(16)
                        }"""
        text = text[:old_timer_header.start()] + new_timer_header + text[old_timer_header.end():]
        print(f"Updated TranscriptTabView timer header in {file_path}")

    # Add bottom shortcuts in TranscriptTabView after segments list
    old_padding_bottom = ".padding(16)\n                    }\n                    .onChange(of: session.segments.count)"
    new_padding_bottom = """.padding(16)

                            // 底部便捷切换胶囊 (不用费劲点顶部按钮)
                            if !session.segments.isEmpty {
                                HStack(spacing: 12) {
                                    Button {
                                        onSwitchToTab?(1)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "note.text")
                                                .font(.system(size: 13, weight: .semibold))
                                            Text("查看课堂笔记")
                                                .font(.system(size: 13, weight: .semibold))
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(Color(UIColor.tertiarySystemFill))
                                        .foregroundColor(.primary)
                                        .cornerRadius(16)
                                    }

                                    Button {
                                        onSwitchToTab?(2)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "sparkles")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundColor(.accentColor)
                                            Text("向课堂 AI 提问")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundColor(.accentColor)
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(Color.accentColor.opacity(0.12))
                                        .cornerRadius(16)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                            }
                        }
                    }
                    .onChange(of: session.segments.count)"""
    if old_padding_bottom in text:
        text = text.replace(old_padding_bottom, new_padding_bottom)
        print(f"Added bottom quick jump buttons to TranscriptTabView in {file_path}")

    # 4. Rebuild NotesTabView with recommendation cards and onSwitchToQA
    old_notes_view = re.search(r'struct NotesTabView: View \{.*?
\}

// MARK: - Tab 3', text, re.DOTALL)
    if old_notes_view:
        new_notes_view = """struct NotesTabView: View {
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
                ForEach(NoteStyle.allCases, id: \\.self) { style in
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
                                Text("正在生成【\\(selectedStyle.title)】，约需数秒...")
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

// MARK: - Tab 3"""
        text = text[:old_notes_view.start()] + new_notes_view + text[old_notes_view.end() - len('// MARK: - Tab 3'):]
        print(f"Rebuilt NotesTabView in {file_path}")

    # 5. Rebuild QATabView with enhanced empty cards and thinking bubble
    old_qa_view = re.search(r'struct QATabView: View \{.*?
\}

// MARK: - AudioPlayerControlBar', text, re.DOTALL)
    if old_qa_view:
        new_qa_view = """struct QATabView: View {
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
                            ForEach(quickQuestions, id: \\.self) { q in
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
                                ForEach(quickQuestions, id: \\.self) { q in
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
                                                Label("定位到实录：\\(formatTime(sec))", systemImage: "clock.arrow.circlepath")
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

// MARK: - AudioPlayerControlBar"""
        text = text[:old_qa_view.start()] + new_qa_view + text[old_qa_view.end() - len('// MARK: - AudioPlayerControlBar'):]
        print(f"Rebuilt QATabView in {file_path}")

    # 6. Update RecordingScreen engine switcher to include 10s / 20s / 30s intervals
    old_engine_menu = re.search(r'// 转录引擎快速选择.*?
                        // ˫ģʽ', text, re.DOTALL)
    if old_engine_menu:
        new_engine_menu = """// 转录引擎与分段周期快速选择 (苹果原生 vs 阶跃星辰 ASR 10s/20s)
                        HStack {
                            Text("转录模式")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Menu {
                                Button {
                                    manager.transcriptionEngine = .apple
                                } label: {
                                    HStack {
                                        Text("🎙️ 苹果原生实时识别 (本地免Key)")
                                        if manager.transcriptionEngine == .apple {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }

                                Divider()

                                ForEach(StepfunChunkInterval.allCases, id: \\.self) { interval in
                                    Button {
                                        manager.transcriptionEngine = .stepfun
                                        manager.stepfunChunkInterval = interval
                                    } label: {
                                        HStack {
                                            Text("⚡ 阶跃 ASR - \\(interval.title)")
                                            if manager.transcriptionEngine == .stepfun && manager.stepfunChunkInterval == interval {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: manager.transcriptionEngine == .apple ? "applelogo" : "bolt.fill")
                                        .font(.caption2)
                                    Text(manager.transcriptionEngine == .apple ? "苹果原生实时" : "阶跃 ASR (\\(manager.stepfunChunkInterval.shortTitle))")
                                        .font(.caption.bold())
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

                        // ˫ģʽ"""
        text = text[:old_engine_menu.start()] + new_engine_menu + text[old_engine_menu.end() - len('// ˫ģʽ'):]
        print(f"Updated RecordingScreen engine menu in {file_path}")

    # 7. Update SettingsScreen to add Chunk Interval picker
    settings_target = 'Section(\n                    header: Text("语音转录引擎偏好"),'
    if settings_target in text and 'stepfunChunkInterval' not in text:
        old_settings_block = re.search(r'Section\(\s+header: Text\("语音转录引擎偏好"\),.*?
                \}', text, re.DOTALL)
        if old_settings_block:
            new_settings_block = """Section(
                    header: Text("语音转录引擎与分段模式"),
                    footer: Text(manager.transcriptionEngine == .apple ? "苹果原生：内置 iOS 本地模型，离线可用，不耗流量，边录音边实时出字。" : "阶跃星辰 ASR：基于 stepaudio-2.5-asr 云端学术模型，每 10~20 秒自动切片转录，公式与专业术语准确率极高。")
                ) {
                    Picker("转录引擎", selection: $manager.transcriptionEngine) {
                        ForEach(TranscriptionEngine.allCases, id: \\.self) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())

                    if manager.transcriptionEngine == .stepfun {
                        Picker("切片转录间隔", selection: $manager.stepfunChunkInterval) {
                            ForEach(StepfunChunkInterval.allCases, id: \\.self) { interval in
                                Text(interval.title).tag(interval)
                            }
                        }
                    }

                    HStack {
                        Label(
                            manager.transcriptionEngine == .apple ? "苹果原生识别引擎 (已激活)" : "阶跃星辰 ASR - \\(manager.stepfunChunkInterval.shortTitle) (已激活)",
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
                }"""
            text = text[:old_settings_block.start()] + new_settings_block + text[old_settings_block.end():]
            print(f"Updated SettingsScreen in {file_path}")

    with open(file_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    print(f"Completed updates to {file_path}")

for target_dir in [r'd:\antigrity\竞赛罗盘\ios\ClassroomApp', r'D:\antigrity\建大课堂录音-iOS\ios\ClassroomApp']:
    update_content_view(f"{target_dir}\\ContentView.swift")
