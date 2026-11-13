import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Edits the header for one script, with a live side-by-side preview of the result.
struct DocumentView: View {
    @Bindable var document: HeaderDocument
    let jamf: JamfModel
    let onClose: () -> Void

    @State private var isConfirmingSave = false
    @State private var isConfirmingPush = false
    @State private var isPushing = false
    @State private var isExporting = false
    /// What Save As or Save README As is saving.
    @State private var exportKind: ExportKind = .script
    @State private var saveError: String?
    @State private var toast: String?
    /// Shows or hides the preview pane; remembered between launches.
    @AppStorage("showsPreview") private var showsPreview = true

    private static let markdownUTType = UTType(filenameExtension: "md") ?? .plainText

    private enum ExportKind {
        case script, readme
    }

    private var hasSaveError: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    var body: some View {
        HSplitView {
            HeaderForm(document: document)
                .frame(minWidth: 400, idealWidth: 460, maxWidth: showsPreview ? 620 : .infinity)
            if showsPreview {
                PreviewPane(document: document)
                    .frame(minWidth: 480)
            }
        }
        .navigationTitle(document.fileName)
        .navigationSubtitle(document.versionSummary)
        .toolbar { toolbar }
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .confirmationDialog(document.mode.includesHeader ? "Replace the header in \(document.fileName)?"
                                                         : "Add comments to \(document.fileName)?",
                            isPresented: $isConfirmingSave) {
            Button("Save") { save() }
        } message: {
            Text(document.saveSummary)
        }
        .confirmationDialog("Update “\(document.jamfSource?.item.name ?? "")” in Jamf Pro?", isPresented: $isConfirmingPush) {
            Button("Update in Jamf Pro") { push() }
        } message: {
            Text("The \(document.jamfSource?.item.kind.noun ?? "script") in \(document.jamfSource?.instanceName ?? "Jamf Pro") is replaced with version \(document.version). Policies and inventory updates use it straight away.\n\n\(AppDisclaimer.text)")
        }
        .fileExporter(isPresented: $isExporting,
                      document: ScriptFile(text: exportKind == .readme ? document.readme : document.rendered),
                      contentType: exportKind == .readme ? Self.markdownUTType : .plainText,
                      defaultFilename: exportKind == .readme ? document.readmeFileName : document.fileName) { result in
            switch result {
            case .success(let url):
                if exportKind == .readme {
                    show("Saved \(url.lastPathComponent)")
                    return
                }
                do {
                    try document.didSave(to: url)
                    show("Saved \(url.lastPathComponent)")
                } catch {
                    saveError = error.localizedDescription
                }
            case .failure(let error):
                saveError = error.localizedDescription
            }
        }
        .alert("Couldn't Save", isPresented: hasSaveError) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(document.rendered, forType: .string)
                show("Copied the script")
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy the script as it will be saved")

            Button {
                exportBundle()
            } label: {
                Label("Download Script & README…", systemImage: "arrow.down.doc")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help("Save the script and its README.md together in a folder named after the script (defaults to Desktop)")

            Button {
                exportKind = .script
                isExporting = true
            } label: {
                Label("Save As…", systemImage: "square.and.arrow.down.on.square")
            }
            .help("Save a copy of the script as shown in the preview")

            Button {
                exportKind = .readme
                isExporting = true
            } label: {
                Label("Save README As…", systemImage: "doc.richtext")
            }
            .help("Save a standalone Markdown README describing this script")

            Button {
                writeReadme()
            } label: {
                if document.isWritingReadme {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Write README", systemImage: "apple.intelligence")
                }
            }
            .disabled(document.isWritingReadme)
            .help(ReadmeWriter.unavailableReason
                  ?? "Use Apple Intelligence to explain how the script works in the README (overview, steps and notes)")

            Toggle(isOn: $showsPreview) {
                Label("Preview", systemImage: "sidebar.right")
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .help(showsPreview ? "Hide the preview" : "Show the preview")

            if let source = document.jamfSource {
                Button {
                    isConfirmingPush = true
                } label: {
                    if isPushing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Update in Jamf Pro", systemImage: "icloud.and.arrow.up")
                    }
                }
                .keyboardShortcut("s")
                .disabled(isPushing)
                .help("Write the new header into the \(source.item.kind.noun) in \(source.instanceName)")
            } else {
                Button {
                    isConfirmingSave = true
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s")
                .disabled(document.url == nil)
                .help("Write the changes into the original file")
            }

            Button(action: onClose) {
                Label("Close", systemImage: "xmark")
            }
            .keyboardShortcut("w")
            .help("Close this script")
        }
    }

    private func save() {
        do {
            try document.save()
            show("Saved \(document.fileName)")
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Sends the script with its new header back to Jamf Pro, then reads it back to check it.
    private func push() {
        guard let source = document.jamfSource else { return }
        let text = document.rendered
        isPushing = true
        Task {
            defer { isPushing = false }
            do {
                try await jamf.push(text, to: source)
                document.didSave(text)
                show("Updated \(source.item.name) in Jamf Pro")
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    /// Has Apple Intelligence write the README's overview, steps and notes from the script.
    private func writeReadme() {
        Task {
            do {
                try await document.writeReadme()
                show("README written with Apple Intelligence")
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    /// Prompts the user for a destination folder (defaulting to Desktop) and writes both script and README.
    private func exportBundle() {
        let panel = NSOpenPanel()
        panel.title = "Download Script & README"
        panel.prompt = "Download"
        panel.message = "Choose a destination folder for \(document.exportFolderName)"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK, let parentURL = panel.url else { return }

        do {
            let folderURL = try document.exportToFolder(in: parentURL)
            if let source = document.jamfSource { jamf.recordDownload(of: source) }
            show("Saved script and README to \(folderURL.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([folderURL])
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if toast == message { toast = nil } }
        }
    }
}

/// The settings and fields that make up the header.
private struct HeaderForm: View {
    @Bindable var document: HeaderDocument

    var body: some View {
        Form {
            if !document.checks.isEmpty {
                Section {
                    ForEach(document.checks, id: \.self) { check in
                        Label(check, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                } header: {
                    Text("Check These")
                }
            }

            if document.hasHouseHeader {
                Section {
                    Toggle("Rebuild in the current format", isOn: $document.rebuildsExistingHeader)
                } header: {
                    Text("Existing Header")
                } footer: {
                    Text(document.rebuildsExistingHeader
                         ? "Output, Deployment, Requirements, Exit Codes, Sections and the Disclaimer are rebuilt from the code and today's settings. Description, Author, Created and the Change Log are kept."
                         : "This script already has a header, so its wording is kept. Turn this on to rebuild it in the current format.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Script") {
                Picker("Type", selection: $document.kind) {
                    ForEach(ScriptKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Language", selection: $document.language) {
                    ForEach(ScriptLanguage.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Script Name", text: $document.fileName)
                    .disabled(document.url != nil)
                TextField("Description", text: $document.descriptionText,
                          prompt: Text("What the script does and why"), axis: .vertical)
                    .lineLimit(2...6)
                TextField("Author", text: $document.author, prompt: Text(HeaderDocument.unknownAuthor))
                TextField("Updated By", text: $document.updatedBy)
            }

            Section("Jamf Pro") {
                if document.kind == .script {
                    Picker("Trigger", selection: $document.trigger) {
                        ForEach(JamfTrigger.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if document.trigger == .customEvent {
                        TextField("Custom Event", text: $document.customEvent, prompt: Text("e.g. installChrome"))
                    }
                    Picker("Frequency", selection: $document.frequency) {
                        ForEach(ExecutionFrequency.allCases) { Text($0.rawValue).tag($0) }
                    }
                } else {
                    Picker("Data Type", selection: $document.dataType) {
                        ForEach(EADataType.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                TextField("Minimum OS", text: $document.minimumOS, prompt: Text("e.g. macOS 13 Ventura"))
            }

            Section {
                Picker("Change", selection: $document.bump) {
                    ForEach(VersionBump.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Version") {
                    Text("\(document.existingVersion ?? "\(HeaderDocument.assumedVersion) (assumed)") → \(document.version)")
                }
                if document.hasHouseHeader {
                    TextField("Change Log", text: $document.changeNote, prompt: Text("What changed"), axis: .vertical)
                        .lineLimit(1...3)
                } else {
                    LabeledContent("Change Log", value: HeaderDocument.headerAddedNote)
                }
                TextField("Created", text: $document.created)
                LabeledContent("Updated", value: "\(HeaderDate.today) by \(document.updatedBy)")
            } header: {
                Text("Version")
            } footer: {
                Text(document.bump.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(HeaderDocument.Generated.allCases, id: \.self) { field in
                GeneratedSection(document: document, field: field)
            }

            RowsSection(title: "Parameters", keyPrompt: "$4", valuePrompt: "Label in Jamf Pro",
                        rows: $document.parameters)
            RowsSection(title: "Sections", keyPrompt: "Name", valuePrompt: "What it does",
                        rows: $document.sections)
            RowsSection(title: "Exit Codes", keyPrompt: "1", valuePrompt: "Meaning",
                        rows: $document.exitCodes)

            Section {
                Toggle("Include Disclaimer", isOn: $document.includeDisclaimer)
                if document.includeDisclaimer {
                    TextField("Disclaimer", text: $document.disclaimerText, axis: .vertical)
                        .lineLimit(2...5)
                        .labelsHidden()
                    if document.disclaimerText != HeaderDocument.standardDisclaimer {
                        Button("Use Standard Disclaimer") { document.disclaimerText = HeaderDocument.standardDisclaimer }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            } header: {
                Text("Disclaimer")
            } footer: {
                Text("Your choice and wording are remembered for the next script you save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !document.changeLog.isEmpty {
                Section("Change Log") {
                    ForEach(document.changeLog) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.version) · \(entry.date) · \(entry.author)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.note)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// An editable field that is worked out from the code unless the user changes it.
private struct GeneratedSection: View {
    @Bindable var document: HeaderDocument
    let field: HeaderDocument.Generated

    var body: some View {
        Section {
            TextField(field.rawValue, text: Binding(
                get: { document.text(for: field) },
                set: { document.overrides[field] = $0 }
            ), axis: .vertical)
            .lineLimit(2...8)
            .labelsHidden()
        } header: {
            HStack {
                Text(field.rawValue)
                Spacer()
                if document.isOverridden(field) {
                    Button("Use Values from Code") { document.overrides[field] = nil }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        } footer: {
            Text(document.isOverridden(field) ? "Edited, or kept from the existing header." : "Worked out from the code and Jamf Pro settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Two-column rows such as exit codes, with add and remove buttons.
private struct RowsSection: View {
    let title: String
    let keyPrompt: String
    let valuePrompt: String
    @Binding var rows: [HeaderRow]

    var body: some View {
        Section {
            ForEach($rows) { $row in
                HStack {
                    TextField("Key", text: $row.key, prompt: Text(keyPrompt))
                        .frame(width: 110)
                        .labelsHidden()
                    TextField("Value", text: $row.value, prompt: Text(valuePrompt))
                        .labelsHidden()
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(row.key)")
                }
            }
            Button {
                rows.append(HeaderRow(key: "", value: ""))
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text(title)
        } footer: {
            if rows.isEmpty, title != "Exit Codes" {
                Text("None found in the code, so this section is left out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Side-by-side preview showing both the script and the README, with line numbers in both windows.
private struct PreviewPane: View {
    let document: HeaderDocument

    enum PreviewTab: String, CaseIterable, Identifiable {
        case sideBySide = "Side by Side"
        case script = "Script"
        case readme = "README"
        case diff = "Before & After"

        var id: String { rawValue }
    }

    @State private var selectedTab: PreviewTab = .sideBySide

    var body: some View {
        VStack(spacing: 0) {
            // Mode selector header
            HStack {
                Picker("Preview Mode", selection: $selectedTab) {
                    ForEach(PreviewTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)

                Spacer()

                if selectedTab == .sideBySide {
                    Text("\(document.rendered.components(separatedBy: "\n").count) script lines · \(document.readme.components(separatedBy: "\n").count) readme lines")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            switch selectedTab {
            case .sideBySide:
                HSplitView {
                    CodeWindowView(
                        title: document.fileName,
                        systemImage: "terminal",
                        badge: "\(document.rendered.components(separatedBy: "\n").count) lines",
                        text: document.rendered,
                        headerLineCount: document.headerLineCount,
                        commentLines: document.output.commentLines,
                        onCopy: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(document.rendered, forType: .string)
                        }
                    )
                    .frame(minWidth: 240)

                    CodeWindowView(
                        title: "README.md",
                        systemImage: "doc.richtext",
                        badge: "\(document.readme.components(separatedBy: "\n").count) lines",
                        text: document.readme,
                        isMarkdown: true,
                        onCopy: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(document.readme, forType: .string)
                        }
                    )
                    .frame(minWidth: 240)
                }

            case .script:
                CodeWindowView(
                    title: document.fileName,
                    systemImage: "terminal",
                    badge: "\(document.rendered.components(separatedBy: "\n").count) lines",
                    text: document.rendered,
                    headerLineCount: document.headerLineCount,
                    commentLines: document.output.commentLines,
                    onCopy: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(document.rendered, forType: .string)
                    }
                )

            case .readme:
                CodeWindowView(
                    title: "README.md",
                    systemImage: "doc.richtext",
                    badge: "\(document.readme.components(separatedBy: "\n").count) lines",
                    text: document.readme,
                    isMarkdown: true,
                    onCopy: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(document.readme, forType: .string)
                    }
                )

            case .diff:
                HSplitView {
                    CodeWindowView(
                        title: "Original",
                        systemImage: "doc.text",
                        badge: "\(document.originalText.components(separatedBy: "\n").count) lines",
                        text: document.originalText,
                        onCopy: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(document.originalText, forType: .string)
                        }
                    )
                    .frame(minWidth: 240)

                    CodeWindowView(
                        title: "Updated",
                        systemImage: "checkmark.circle",
                        badge: "\(document.rendered.components(separatedBy: "\n").count) lines",
                        text: document.rendered,
                        headerLineCount: document.headerLineCount,
                        commentLines: document.output.commentLines,
                        onCopy: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(document.rendered, forType: .string)
                        }
                    )
                    .frame(minWidth: 240)
                }
            }
        }
    }
}

/// A single code window showing title bar, line count, copy action, and scrollable numbered code.
private struct CodeWindowView: View {
    let title: String
    let systemImage: String
    let badge: String
    let text: String
    var headerLineCount: Int = 0
    var commentLines: Set<Int> = []
    var isMarkdown: Bool = false
    var onCopy: (() -> Void)? = nil

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer()

                Text(badge)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor), in: Capsule())

                if let onCopy {
                    Button {
                        onCopy()
                        withAnimation { copied = true }
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            withAnimation { copied = false }
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(copied ? "Copied!" : "Copy contents")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))

            Divider()

            NumberedCodeView(
                text: text,
                headerLineCount: headerLineCount,
                commentLines: commentLines,
                isMarkdown: isMarkdown
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// A scrollable code view with an aligned line numbers gutter on the left.
private struct NumberedCodeView: View {
    let text: String
    var headerLineCount: Int = 0
    var commentLines: Set<Int> = []
    var isMarkdown: Bool = false

    private static let monoFont: Font = .system(size: 11.5, weight: .regular, design: .monospaced)

    /// Lines per rendered block. A single `Text` taller than the GPU's maximum texture size
    /// (~16k px) silently draws nothing, so large scripts are split into blocks that each stay
    /// well under that limit (200 lines ≈ 3,400 pt) and are created lazily as they scroll in.
    private static let chunkSize = 200

    /// One block of consecutive lines: its first line index, gutter numbers and styled content.
    private struct Chunk: Identifiable {
        let id: Int
        let gutter: String
        let content: AttributedString
    }

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        let totalLines = max(1, lines.count)
        let gutterDigits = max(3, String(totalLines).count)
        let gutterWidth = CGFloat(gutterDigits * 8 + 14)
        let chunks = makeChunks(lines)

        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(chunks) { chunk in
                    let isFirst = chunk.id == 0
                    let isLast = chunk.id == chunks.last?.id
                    HStack(alignment: .top, spacing: 0) {
                        // Line numbers gutter
                        Text(chunk.gutter)
                            .font(Self.monoFont)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.trailing)
                            .lineSpacing(3)
                            .frame(width: gutterWidth, alignment: .trailing)
                            .padding(.horizontal, 6)
                            .padding(.top, isFirst ? 8 : 0)
                            .padding(.bottom, isLast ? 8 : 3)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))

                        Rectangle()
                            .fill(Color(nsColor: .separatorColor).opacity(0.5))
                            .frame(width: 1)

                        // Code or Markdown content
                        Text(chunk.content)
                            .font(Self.monoFont)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.top, isFirst ? 8 : 0)
                            .padding(.bottom, isLast ? 8 : 3)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Splits the lines into `chunkSize` blocks, styling each with its global line indices so
    /// header and comment colouring still line up with the whole-file line numbers.
    private func makeChunks(_ lines: [String]) -> [Chunk] {
        stride(from: 0, to: max(1, lines.count), by: Self.chunkSize).map { start in
            let end = min(start + Self.chunkSize, lines.count)
            let slice = start < end ? Array(lines[start..<end]) : [""]
            let gutter = (start + 1...start + slice.count).map(String.init).joined(separator: "\n")
            let content = isMarkdown
                ? attributedMarkdown(for: slice.joined(separator: "\n"))
                : attributedScript(for: slice, startIndex: start)
            return Chunk(id: start, gutter: gutter, content: content)
        }
    }

    private func attributedScript(for lines: [String], startIndex: Int) -> AttributedString {
        var result = AttributedString()
        for (offset, line) in lines.enumerated() {
            let index = startIndex + offset
            var str = AttributedString(line)
            if index < headerLineCount {
                str.foregroundColor = .systemBlue
            } else if commentLines.contains(index) {
                str.foregroundColor = .systemGreen
            } else {
                str.foregroundColor = .primary
            }
            result += str
            if offset < lines.count - 1 {
                result += AttributedString("\n")
            }
        }
        return result
    }

    private func attributedMarkdown(for text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n")
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var str = AttributedString(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                str.foregroundColor = .systemIndigo
                str.inlinePresentationIntent = .stronglyEmphasized
            } else if trimmed.hasPrefix("|") {
                str.foregroundColor = .systemBlue
            } else if trimmed.hasPrefix("-") || trimmed.firstMatch(#"^\d+\."#) != nil {
                str.foregroundColor = .systemTeal
            } else {
                str.foregroundColor = .primary
            }
            result += str
            if index < lines.count - 1 {
                result += AttributedString("\n")
            }
        }
        return result
    }
}

/// Plain text wrapper used by Save As.
struct ScriptFile: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
