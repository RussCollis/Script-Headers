import AppKit
import Observation

/// The scripts open in the window.
@Observable
final class HeaderLibrary {
    var documents: [HeaderDocument] = []
    var selection: HeaderDocument.ID?
    var isImporting = false
    var isBrowsingJamf = false
    let jamf = JamfModel()
    var errorMessage: String?
    /// Files whose security-scoped access must be released when they close.
    private var scopedURLs: [HeaderDocument.ID: URL] = [:]

    var selected: HeaderDocument? {
        documents.first { $0.id == selection }
    }

    /// Opens scripts from Finder, the Open panel or a drop. Files already open are selected instead.
    func open(_ urls: [URL]) {
        var failed: [String] = []
        for url in urls {
            if let existing = documents.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
                selection = existing.id
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  !data.contains(0) else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                failed.append(url.lastPathComponent)
                continue
            }
            let document = HeaderDocument(text: text, fileName: url.lastPathComponent, url: url)
            documents.append(document)
            if scoped { scopedURLs[document.id] = url }
            selection = document.id
        }
        if !failed.isEmpty {
            errorMessage = "Couldn't read \(failed.joined(separator: ", ")) as a text script."
        }
    }

    /// Opens a script or extension attribute read from Jamf Pro. Items already open are selected instead.
    func open(_ record: JamfRecord, from instance: JamfInstance) {
        if let existing = documents.first(where: {
            $0.jamfSource?.instanceID == instance.id && $0.jamfSource?.item.id == record.item.id
        }) {
            selection = existing.id
            return
        }
        let source = JamfSource(instanceID: instance.id, instanceName: instance.displayName, item: record.item, serverURL: instance.serverURL)
        let document = HeaderDocument(record: record, source: source)
        documents.append(document)
        selection = document.id
    }

    /// Starts a document from a script copied to the clipboard.
    func newFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmed.isEmpty else {
            errorMessage = "The clipboard doesn't contain any text."
            return
        }
        let language = ScriptLanguage.detect(shebang: text.components(separatedBy: "\n").first, fileName: "")
        let fileExtension = switch language {
        case .python: "py"
        case .powerShell: "ps1"
        case .appleScript: "applescript"
        case .javaScript: "js"
        case .zsh: "zsh"
        default: "sh"
        }
        let document = HeaderDocument(text: text, fileName: "script.\(fileExtension)", url: nil)
        documents.append(document)
        selection = document.id
    }

    func close(_ id: HeaderDocument.ID) {
        scopedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        documents.removeAll { $0.id == id }
        if selection == id { selection = documents.last?.id }
    }
}
