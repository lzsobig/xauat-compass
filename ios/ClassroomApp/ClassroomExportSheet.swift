import SwiftUI

struct ClassroomExportSheet: View {
    @EnvironmentObject var manager: ClassroomManager
    @Environment(\.presentationMode) var presentationMode
    let session: LessonSession
    @State private var options = ClassroomExportOptions()
    @State private var exporting = false
    @State private var errorMessage = ""
    @State private var shareItem: ShareItem?

    var body: some View {
        NavigationView {
            Form {
                Section("导出内容") {
                    ForEach(ClassroomExportSection.allCases, id: \.self) { section in
                        Toggle(section.rawValue, isOn: Binding(get: {
                            options.sections.contains(section)
                        }, set: { selected in
                            if selected { options.sections.insert(section) }
                            else { options.sections.remove(section) }
                        }))
                    }
                }
                Section("文件格式") {
                    Picker("格式", selection: $options.format) {
                        ForEach(ClassroomExportFormat.allCases, id: \.self) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    Toggle("包含图片", isOn: $options.includeImages)
                        .disabled(options.format == .txt)
                    if options.format == .markdown && options.includeImages {
                        Text("导出 ZIP，包含 Markdown 正文和 images 图片文件夹")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if options.format == .txt {
                        Text("纯文本保留时间戳和图片位置标记")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Section {
                    Button(action: export) {
                        HStack {
                            Spacer()
                            if exporting { ProgressView() }
                            Text(exporting ? "正在生成文件" : "导出并分享")
                            Spacer()
                        }
                    }
                    .disabled(exporting || options.sections.isEmpty)
                    if !errorMessage.isEmpty {
                        Text(errorMessage).font(.caption).foregroundColor(.red)
                    }
                }
            }
            .disabled(exporting)
            .navigationTitle("导出课堂")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }.disabled(exporting)
                }
            }
        }
        .sheet(item: $shareItem) { item in ShareSheet(activityItems: [item.fileURL]) }
        .interactiveDismissDisabled(exporting)
    }

    private func export() {
        guard !exporting else { return }
        exporting = true
        errorMessage = ""
        let current = manager.sessions.first(where: { $0.id == session.id }) ?? session
        let selectedOptions = options
        var urls: [UUID: URL] = [:]
        for attachment in current.attachments { urls[attachment.id] = manager.attachmentURL(attachment) }
        let imageURLs = urls
        Task {
            defer { exporting = false }
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try ClassroomExporter.export(session: current, options: selectedOptions) { attachment in
                        imageURLs[attachment.id] ?? URL(fileURLWithPath: "/missing-classroom-attachment")
                    }
                }.value
                shareItem = ShareItem(fileURL: output)
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
