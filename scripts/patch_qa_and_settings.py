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
"""

new_recording_engine_menu = """                        // 转录引擎与分段周期快速选择 (苹果原生 vs 阶跃星辰 ASR 10s/20s)
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
                        .padding(.horizontal, 4)"""

new_settings_section = """                Section(
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

for target_dir in [r'd:\antigrity\竞赛罗盘\ios\ClassroomApp', r'D:\antigrity\建大课堂录音-iOS\ios\ClassroomApp']:
    p = f"{target_dir}\\ContentView.swift"
    with open(p, 'r', encoding='utf-8') as f:
        text = f.read()

    # 1. Replace QATabView
    idx_qa1 = text.find('struct QATabView: View')
    idx_qa2 = text.find('struct LiveRecordingControlBar: View')
    if idx_qa1 != -1 and idx_qa2 != -1:
        text = text[:idx_qa1] + new_qa_view + '\n\n// MARK: - 底部录音控制栏\n\n' + text[idx_qa2:]
        print(f"Replaced QATabView in {p}")

    # 2. Replace engine switcher on RecordingScreen
    idx_eng1 = text.find('// 转录引擎快速选择')
    if idx_eng1 == -1:
        idx_eng1 = text.find('// 转录引擎与分段周期快速选择')
    idx_eng2 = text.find('// ˫ģʽ', idx_eng1) if idx_eng1 != -1 else -1
    if idx_eng1 != -1 and idx_eng2 != -1:
        text = text[:idx_eng1] + new_recording_engine_menu + '\n\n                        ' + text[idx_eng2:]
        print(f"Replaced RecordingScreen menu in {p}")

    # 3. Replace settings section
    idx_set1 = text.find('Section(\n                    header: Text("语音转录引擎')
    if idx_set1 != -1:
        idx_set2 = text.find('Section(\n                    header: Text("AI 助教大模型')
        if idx_set2 != -1:
            text = text[:idx_set1] + new_settings_section + '\n\n                ' + text[idx_set2:]
            print(f"Replaced SettingsScreen section in {p}")

    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    print(f"Saved {p}")
