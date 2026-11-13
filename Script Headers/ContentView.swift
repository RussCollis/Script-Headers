import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var library: HeaderLibrary
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            List(selection: $library.selection) {
                if !library.documents.isEmpty {
                    Section("Open Scripts") {
                        ForEach(library.documents) { document in
                            DocumentRow(document: document, isSelected: library.selection == document.id) {
                                library.close(document.id)
                            }
                                .tag(document.id)
                                .contextMenu {
                                    Button("Close") { library.close(document.id) }
                                }
                        }
                    }
                }
            }
            .onDeleteCommand {
                if let selection = library.selection { library.close(selection) }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .top) { SidebarHeader() }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        library.isImporting = true
                    } label: {
                        Label("Open Scripts…", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        library.isBrowsingJamf = true
                    } label: {
                        Label("Load from Jamf Pro…", systemImage: "server.rack")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        library.newFromClipboard()
                    } label: {
                        Label("New from Clipboard", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    SidebarFooter()
                }
                .buttonStyle(.bordered)
                // White keeps the buttons legible on the blue gradient.
                .tint(.white)
                .foregroundStyle(.white)
                .controlSize(.large)
                .padding(.horizontal, 12)
            }
            .background { SidebarBackground().ignoresSafeArea() }
            // Dark scheme keeps labels, symbols and selection legible on the gradient.
            .environment(\.colorScheme, .dark)
        } detail: {
            if let document = library.selected {
                DocumentView(document: document, jamf: library.jamf) {
                    library.close(document.id)
                }
                .id(document.id)
            } else {
                ContentUnavailableView {
                    Label("No Script Open", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Drop Jamf Pro scripts or extension attributes here, open them, or load them straight from Jamf Pro to add a standard header.")
                } actions: {
                    HStack {
                        Button("Open Scripts…") { library.isImporting = true }
                            .buttonStyle(.borderedProminent)
                        Button("Load from Jamf Pro…") { library.isBrowsingJamf = true }
                    }
                }
                .navigationTitle("Script Scribe")
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.open(urls.filter(\.isFileURL))
            return true
        } isTargeted: { isDropTargeted = $0 }
        .fileImporter(isPresented: $library.isImporting, allowedContentTypes: [.text, .script, .data],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): library.open(urls)
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $library.isBrowsingJamf) {
            JamfBrowser(jamf: library.jamf) { record, instance in
                library.open(record, from: instance)
            }
        }
        .alert("Script Scribe", isPresented: Binding(get: { library.errorMessage != nil },
                                                    set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
        // A fixed tint stops the system accent colour showing on standard controls.
        .tint(.blue)
    }
}

/// A script in the sidebar, with a dot until its header has been saved. A close button shows
/// while the row is selected or the pointer is over it.
private struct DocumentRow: View {
    let document: HeaderDocument
    let isSelected: Bool
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack {
            label
            Spacer(minLength: 4)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.large)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Close \(document.fileName)")
            .accessibilityLabel("Close \(document.fileName)")
            .opacity(isHovering || isSelected ? 1 : 0)
        }
        .onHover { isHovering = $0 }
    }

    private var label: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(document.fileName)
                    .lineLimit(1)
                Text("\(document.kind.rawValue) · v\(document.isUpToDate ? document.savedVersion ?? document.version : document.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: document.lastSaved != nil ? "checkmark.circle.fill"
                  : document.jamfSource != nil ? "server.rack" : document.kind.symbol)
        }
    }
}

/// Blue to indigo gradient behind the sidebar, matching the other apps in the library.
struct SidebarBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.36, green: 0.66, blue: 0.98),
                Color(red: 0.16, green: 0.40, blue: 0.86),
                Color(red: 0.24, green: 0.18, blue: 0.62)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Logo and app name shown at the top of the sidebar.
struct SidebarHeader: View {
    var body: some View {
        VStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 110, height: 110)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                .accessibilityHidden(true)
            Text("Script Scribe")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .padding(.horizontal, 12)
    }
}

/// App version shown at the foot of the sidebar.
struct SidebarFooter: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Text(version)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}

#Preview {
    ContentView(library: HeaderLibrary())
}
