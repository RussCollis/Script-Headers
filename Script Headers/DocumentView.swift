import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Edits the header for one script, with a live preview of the result.
struct DocumentView: View {
    @Bindable var document: HeaderDocument
    let jamf: JamfModel
    let onClose: () -> Void

    @State private var isConfirmingSave = false
    @State private var isConfirmingPush = false
    @State private var isPushing = false
    @State private var isExporting = false
    @State private var saveError: String?
    @State private var toast: String?

    var body: some View {
        HSplitView {
            HeaderForm(document: document)
                .frame(minWidth: 400, idealWidth: 460, maxWidth: 620)
            ScriptPreview(document: document)
                .frame(minWidth: 420)
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
        .confirmationDialog("Replace the header in \(document.fileName)?", isPresented: $isConfirmingSave) {
            Button("Save") { save() }
        } message: {
            Text("The file is overwritten with version \(document.version). The code below the header isn't changed.")
        }
        .confirmationDialog("Update “\(document.jamfSource?.item.name ?? "")” in Jamf Pro?", isPresented: $isConfirmingPush) {
            Button("Update in Jamf Pro") { push() }
        } message: {
            Text("The \(document.jamfSource?.item.kind.noun ?? "script") in \(document.jamfSource?.instanceName ?? "Jamf Pro") is replaced with version \(document.version). Policies and inventory updates use it straight away.\n\n\(AppDisclaimer.text)")
        }
        .fileExporter(isPresented: $isExporting, document: ScriptFile(text: document.rendered),
                      contentType: .plainText, defaultFilename: document.fileName) { result in
            switch result {
            case .success(let url):
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
        .alert("Couldn't Save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
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
                show("Copied the script with its header")
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy the script with its new header")

            Button {
                isExporting = true
            } label: {
                Label("Save As…", systemImage: "square.and.arrow.down.on.square")
            }
            .help("Save a copy with the new header")

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
                .help("Write the new header into the original file")
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

/// The script as it will be saved, with the new header highlighted.
private struct ScriptPreview: View {
    let document: HeaderDocument

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(attributed)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var attributed: AttributedString {
        let lines = document.rendered.components(separatedBy: "\n")
        let headerEnd = min(document.headerLineCount, lines.count)
        var header = AttributedString(lines[..<headerEnd].joined(separator: "\n") + "\n")
        header.foregroundColor = .blue
        // Large scripts are cut short; the whole file is still saved.
        let bodyLines = lines[headerEnd...].prefix(1500)
        var body = AttributedString(bodyLines.joined(separator: "\n"))
        body.foregroundColor = .primary
        if lines.count - headerEnd > 1500 {
            var more = AttributedString("\n… \(lines.count - headerEnd - 1500) more lines")
            more.foregroundColor = .secondary
            body += more
        }
        return header + body
    }
}

/// Plain text wrapper used by Save As.
struct ScriptFile: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
