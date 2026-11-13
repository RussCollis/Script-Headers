import SwiftUI

/// Which items the browser lists, by whether they already have a standard header
/// or have been downloaded on this Mac.
enum HeaderFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case updated = "Updated"
    case notUpdated = "Not Updated"
    case downloaded = "Downloaded"
    case notDownloaded = "Not Downloaded"

    var id: String { rawValue }

    /// `jamf` supplies the download dates, which are kept per instance on this Mac rather than on the item.
    func includes(_ item: JamfItem, in jamf: JamfModel) -> Bool {
        switch self {
        case .all: true
        case .updated: item.status.hasHeader
        case .notUpdated: item.status == .noHeader
        case .downloaded: jamf.lastDownloaded(item) != nil
        case .notDownloaded: jamf.lastDownloaded(item) == nil
        }
    }
}

/// Connects to a Jamf Pro instance and opens scripts or extension attributes to add headers to.
struct JamfBrowser: View {
    @Bindable var jamf: JamfModel
    /// Called with each chosen item, freshly read from Jamf Pro.
    var onLoad: (JamfRecord, JamfInstance) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: JamfItem.Kind = .script
    @AppStorage("jamfHeaderFilter") private var filter: HeaderFilter = .all
    @AppStorage(HeaderDocument.rebuildKey) private var rebuildsExistingHeaders = false
    @State private var selection = Set<JamfItem.ID>()
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var isConfirmingRemove = false

    var body: some View {
        NavigationStack {
            Group {
                if jamf.isConnected {
                    itemList
                } else {
                    connectForm
                }
            }
            .navigationTitle("Load from Jamf Pro")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if jamf.isConnected {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(selection.count > 1 ? "Open \(selection.count) Items" : "Open") { load() }
                            .disabled(selection.isEmpty || isLoading)
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .tint(.blue)
    }

    // MARK: - Connect

    private var connectForm: some View {
        Form {
            Section("Instance") {
                HStack {
                    instancePicker
                    Button("Add Instance", systemImage: "plus") { jamf.addInstance() }
                        .labelStyle(.iconOnly)
                        .help("Add another Jamf Pro instance")
                    Button("Remove Instance", systemImage: "minus") { isConfirmingRemove = true }
                        .labelStyle(.iconOnly)
                        .disabled(jamf.instances.count < 2)
                        .help("Remove this instance and its saved secret")
                }
                TextField("Name", text: $jamf.instanceName, prompt: Text("e.g. Production"))
                TextField("Server", text: $jamf.serverURL, prompt: Text("https://yourcompany.jamfcloud.com"))
            }
            .confirmationDialog("Remove “\(jamf.selectedInstance?.displayName ?? "")”?",
                                isPresented: $isConfirmingRemove) {
                Button("Remove Instance", role: .destructive) { jamf.removeSelectedInstance() }
            } message: {
                Text("Its client secret is deleted from your keychain. Nothing in Jamf Pro is changed.")
            }

            Section {
                TextField("Client ID", text: $jamf.clientID)
                SecureField("Client Secret", text: $jamf.clientSecret)
                    .onSubmit(connect)
            } header: {
                Text("API Client")
            } footer: {
                Text("Create an API client in Jamf Pro under Settings › API Roles and Clients. Its role needs **Read Scripts** and **Update Scripts**, plus **Read Computer Extension Attributes** and **Update Computer Extension Attributes**. Each instance's secret is stored in your keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(action: connect) {
                    if jamf.isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect to \(jamf.selectedInstance?.displayName ?? "Jamf Pro")")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!jamf.canConnect)

                if let error = jamf.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var instancePicker: some View {
        Picker("Jamf Pro", selection: $jamf.selectedID) {
            ForEach(jamf.instances) { instance in
                Text(instance.displayName).tag(Optional(instance.id))
            }
        }
    }

    // MARK: - Items

    private var filteredItems: [JamfItem] {
        // Extension attributes without a script can't have a header, so they aren't listed.
        let items = (kind == .script ? jamf.scripts : jamf.extensionAttributes)
            .filter { $0.status != .notScript && filter.includes($0, in: jamf) }
        let query = searchText.trimmed
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.localizedStandardContains(query) || $0.category.localizedStandardContains(query) }
    }

    private var itemList: some View {
        VStack(spacing: 0) {
            HStack {
                // Switching instance here disconnects and returns to the connect form.
                instancePicker
                    .labelsHidden()
                    .fixedSize()
                Text(jamf.host)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        do { try await jamf.refresh() } catch { jamf.errorMessage = error.localizedDescription }
                    }
                }
                .labelStyle(.iconOnly)
                .help("Reload the lists from Jamf Pro")
                Button("Disconnect") { jamf.disconnect() }
            }
            .padding([.horizontal, .top], 10)

            HStack {
                Picker("Show", selection: $kind) {
                    ForEach(JamfItem.Kind.allCases) { kind in
                        let items = (kind == .script ? jamf.scripts : jamf.extensionAttributes).filter { $0.status != .notScript }
                        Text("\(kind.rawValue) (\(items.count))").tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker("Header", selection: $filter) {
                    ForEach(HeaderFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Show items by whether they already have a standard header")
            }
            .padding(10)
            .onChange(of: kind) { selection = [] }
            .onChange(of: filter) { selection = [] }

            Toggle("Rebuild existing headers in the current format", isOn: $rebuildsExistingHeaders)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .help("Items that are already updated are opened with their header rebuilt from the code. Description, Author, Created and the Change Log are kept.")

            if let progress = jamf.checkProgress {
                HStack(spacing: 8) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(width: 120)
                    Text("Checking headers… \(progress.done) of \(progress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }

            List(filteredItems, selection: $selection) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        if !item.category.isEmpty {
                            Text(item.category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    HeaderStatusBadge(status: item.status, pushed: jamf.lastPushed(item),
                                      downloaded: jamf.lastDownloaded(item))
                }
                .tag(item.id)
            }
            .searchable(text: $searchText, prompt: "Search \(kind.rawValue.lowercased())")
            .contextMenu(forSelectionType: JamfItem.ID.self) { _ in } primaryAction: { ids in
                selection = ids
                load()
            }
            .overlay {
                if filteredItems.isEmpty {
                    ContentUnavailableView("No \(kind.rawValue)", systemImage: "doc.text.magnifyingglass",
                                           description: Text(!searchText.isEmpty ? "Nothing matches your search."
                                                             : filter == .notDownloaded ? "Every one has been downloaded."
                                                             : filter == .notUpdated ? "Every one has a header."
                                                             : filter != .all ? "None are \(filter.rawValue.lowercased()) yet."
                                                             : "Jamf Pro didn't return any."))
                }
            }

            if isLoading || jamf.errorMessage != nil {
                HStack {
                    if isLoading {
                        ProgressView().controlSize(.small)
                        Text("Reading from Jamf Pro…")
                            .foregroundStyle(.secondary)
                    } else if let error = jamf.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
                .font(.callout)
                .padding(10)
            }
        }
    }

    private func connect() {
        Task { await jamf.connect() }
    }

    /// Reads each selected item and opens it; items that can't be read are reported and skipped.
    private func load() {
        guard let instance = jamf.connectedInstance else { return }
        let items = (kind == .script ? jamf.scripts : jamf.extensionAttributes).filter { selection.contains($0.id) }
        isLoading = true
        jamf.errorMessage = nil
        Task {
            var failures: [String] = []
            for item in items {
                do {
                    onLoad(try await jamf.load(item), instance)
                } catch {
                    failures.append("\(item.name): \(error.localizedDescription)")
                }
            }
            isLoading = false
            if failures.isEmpty {
                dismiss()
            } else {
                jamf.errorMessage = failures.joined(separator: "\n")
            }
        }
    }
}

/// Shows whether an item has a standard header: its version and Updated date, or "No header".
private struct HeaderStatusBadge: View {
    let status: HeaderStatus
    /// When it was last updated from this Mac, if it was.
    let pushed: Date?
    /// When its script and README were last downloaded on this Mac, if they were.
    let downloaded: Date?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            switch status {
            case .header(let version, let updated):
                Label(version.map { "Updated · v\($0)" } ?? "Updated", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let updated, !updated.isEmpty {
                    Text(updated)
                        .foregroundStyle(.secondary)
                }
            case .noHeader:
                Label("No header", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            case .unchecked:
                ProgressView().controlSize(.mini)
            case .failed:
                Label("Couldn't check", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .notScript:
                EmptyView()
            }
            if let pushed {
                Text("Pushed from this Mac \(pushed.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if let downloaded {
                Text("Downloaded \(downloaded.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            } else if status != .notScript {
                Text("Not downloaded")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }
}
