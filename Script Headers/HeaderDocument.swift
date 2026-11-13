import Foundation
import Observation

/// One opened script or extension attribute and the header being built for it.
@Observable
final class HeaderDocument: Identifiable {
    /// Prose fields that are worked out from the code but can be edited.
    enum Generated: String, CaseIterable {
        case output = "Output"
        case deployment = "Deployment"
        case requirements = "Requirements"
    }

    let id = UUID()
    /// Where the script was opened from; nil for scripts pasted from the clipboard or loaded from Jamf Pro.
    var url: URL?
    /// The Jamf Pro script or extension attribute this was loaded from, if any.
    private(set) var jamfSource: JamfSource?
    /// Parameter labels from the Jamf Pro script settings, which name parameters better than the code can.
    private var jamfParameterLabels: [Int: String] = [:]
    /// The Info, Notes or Description saved in Jamf Pro, used when the script has no description.
    private var jamfNotes = ""
    var fileName: String
    private(set) var originalText: String
    private(set) var split: ScriptSplit
    private(set) var parsed: ParsedHeader
    private(set) var analysis: ScriptAnalysis

    var language: ScriptLanguage {
        didSet { if language != oldValue { load(originalText) } }
    }
    var kind: ScriptKind

    // Jamf Pro deployment
    var trigger: JamfTrigger = .recurringCheckIn
    var customEvent = ""
    var frequency: ExecutionFrequency = .oncePerComputer
    var dataType: EADataType = .string
    var minimumOS = UserDefaults.standard.string(forKey: "minimumOS") ?? "macOS 13 Ventura"

    // Header values
    /// The script's original author. Never guessed: "Unknown" unless the existing header names one.
    var author = HeaderDocument.unknownAuthor
    /// Who is adding or updating the header; recorded in Updated and the Change Log.
    var updatedBy = UserDefaults.standard.string(forKey: "updatedBy") ?? "Russell Collis"
    var descriptionText = ""
    var created = HeaderDate.today
    var bump: VersionBump = .patch
    var changeNote = UserDefaults.standard.bool(forKey: HeaderDocument.rebuildKey)
        ? HeaderDocument.rebuildNote : HeaderDocument.updateNote
    var parameters: [HeaderRow] = []
    var sections: [HeaderRow] = []
    var exitCodes: [HeaderRow] = []
    /// Text typed over (or kept from the existing header for) a generated field.
    var overrides: [Generated: String] = [:]

    static let standardDisclaimer = "Provided as is, without warranty of any kind. Test in a non-production "
        + "environment before deploying. Use at your own risk."
    var includeDisclaimer = UserDefaults.standard.object(forKey: "includeDisclaimer") as? Bool ?? true
    /// Rebuilds an existing header in the current format from the code instead of keeping its wording.
    /// Description, author, created date and change log are always kept.
    var rebuildsExistingHeader = UserDefaults.standard.bool(forKey: HeaderDocument.rebuildKey) {
        didSet {
            guard rebuildsExistingHeader != oldValue else { return }
            seed()
            if hasHouseHeader {
                changeNote = rebuildsExistingHeader ? Self.rebuildNote : Self.updateNote
            }
        }
    }
    static let rebuildKey = "rebuildExistingHeaders"
    static let rebuildNote = "Updated header"
    static let updateNote = "Updated header"
    var disclaimerText = UserDefaults.standard.string(forKey: "disclaimer") ?? HeaderDocument.standardDisclaimer

    init(text: String, fileName: String, url: URL?) {
        self.url = url
        self.fileName = fileName
        originalText = text
        let language = ScriptLanguage.detect(shebang: text.components(separatedBy: "\n").first, fileName: fileName)
        self.language = language
        let split = ScriptSplit(text: text, language: language)
        let analysis = ScriptAnalyzer.analyse(split.body, language: language)
        self.split = split
        parsed = HeaderParser.parse(split.headerLines)
        self.analysis = analysis
        kind = analysis.reportsResult ? .extensionAttribute : .script
        seed()
    }

    /// Opens a script or extension attribute read from Jamf Pro.
    convenience init(record: JamfRecord, source: JamfSource) {
        self.init(text: record.contents, fileName: record.item.name, url: nil)
        jamfSource = source
        jamfParameterLabels = record.parameterLabels
        jamfNotes = record.notes
        kind = record.item.kind.scriptKind
        if let dataType = record.dataType { self.dataType = dataType }
        seed()
    }

    /// Re-reads the script, e.g. after saving or changing the language.
    func load(_ text: String) {
        originalText = text
        split = ScriptSplit(text: text, language: language)
        parsed = HeaderParser.parse(split.headerLines)
        analysis = ScriptAnalyzer.analyse(split.body, language: language)
        seed()
    }

    /// Fills the editable values: code first, with useful details folded in from any existing header.
    /// When rebuilding, the existing header's wording is only used where the code has nothing better.
    private func seed() {
        let keepsWording = !rebuildsExistingHeader
        descriptionText = parsed.description.isEmpty ? jamfNotes : parsed.description
        if keepsWording, let disclaimer = parsed.fields[.disclaimer] {
            includeDisclaimer = true
            disclaimerText = disclaimer
        } else if !keepsWording {
            includeDisclaimer = UserDefaults.standard.object(forKey: "includeDisclaimer") as? Bool ?? true
            disclaimerText = UserDefaults.standard.string(forKey: "disclaimer") ?? Self.standardDisclaimer
        }
        author = parsed.fields[.author].flatMap { $0.trimmed.isEmpty ? nil : $0.trimmed } ?? Self.unknownAuthor
        created = parsed.fields[.created].map { HeaderDate.normalise($0) } ?? HeaderDate.today

        overrides = [:]
        if keepsWording {
            if let output = parsed.fields[.output] { overrides[.output] = output }
            if let deployment = parsed.fields[.deployment] { overrides[.deployment] = deployment }
            if let requirements = parsed.fields[.requirements] { overrides[.requirements] = requirements }
        }

        /// Picks the existing meaning or the one read from the code, depending on the mode.
        func meaning(existing: String?, fromCode: String, isGeneric: Bool) -> String {
            guard let existing, !existing.trimmed.isEmpty else { return fromCode }
            return keepsWording || isGeneric || fromCode.isEmpty ? existing : fromCode
        }

        // Rows come from the code; existing meanings are kept where the code still has them.
        exitCodes = analysis.exitCodes.map { row in
            let existing = parsed.exitCodes.first { $0.key == row.key }?.value
            return HeaderRow(key: row.key, value: meaning(existing: existing, fromCode: row.value,
                                                          isGeneric: row.value == ScriptAnalyzer.genericFailure))
        }
        parameters = analysis.parameters.map { row in
            let jamfLabel = Int(row.key.dropFirst()).flatMap { jamfParameterLabels[$0] }
            let existing = parsed.parameters.first { $0.key == row.key }?.value
            return HeaderRow(key: row.key, value: jamfLabel ?? meaning(existing: existing, fromCode: row.value,
                                                                       isGeneric: row.value == "Custom parameter"))
        }
        // Parameters labelled in Jamf Pro are documented even if the code reads them indirectly.
        for (number, label) in jamfParameterLabels.sorted(by: { $0.key < $1.key })
        where !parameters.contains(where: { $0.key == "$\(number)" }) {
            parameters.append(HeaderRow(key: "$\(number)", value: label))
        }
        parameters.sort { (Int($0.key.dropFirst()) ?? 0) < (Int($1.key.dropFirst()) ?? 0) }
        if analysis.sections.isEmpty {
            sections = parsed.sections
        } else {
            sections = analysis.sections.map { row in
                // Hand-written summaries are kept; function lists are refreshed from the code.
                let existing = parsed.sections.first { $0.key.lowercased() == row.key.lowercased() }?.value
                let kept = existing.flatMap { $0.isEmpty || $0.contains("Functions:") ? nil : $0 }
                return HeaderRow(key: row.key, value: meaning(existing: kept, fromCode: row.value, isGeneric: false))
            }
        }
    }

    // MARK: - Version

    static let unknownAuthor = "Unknown"
    /// Version assumed for a script that has never had one.
    static let assumedVersion = "1.0.0"
    static let headerAddedNote = "Header added"

    /// The version in the existing header, if there is one.
    var existingVersion: String? { parsed.version }

    /// True when the script already has a header in the house format, so this is an update.
    var hasHouseHeader: Bool { parsed.fields[.scriptName] != nil }

    /// Adding or updating the header is a change, so the version is always bumped.
    var version: String { bump.apply(to: existingVersion ?? Self.assumedVersion) }

    /// The Change Log: earlier entries plus one for this change.
    var changeLog: [ChangeLogEntry] {
        var entries = parsed.changeLog.map { entry in
            var entry = entry
            if entry.author.isEmpty { entry.author = Self.unknownAuthor }
            return entry
        }
        let note = hasHouseHeader ? changeNote.trimmed : Self.headerAddedNote
        entries.append(ChangeLogEntry(version: version, date: HeaderDate.today, author: updatedBy.trimmed, note: note))
        return entries
    }

    // MARK: - Generated text

    func text(for field: Generated) -> String {
        overrides[field] ?? generated(field)
    }

    func isOverridden(_ field: Generated) -> Bool {
        overrides[field] != nil
    }

    /// The value worked out from the code and the Jamf Pro settings.
    func generated(_ field: Generated) -> String {
        switch field {
        case .output:
            if kind == .extensionAttribute {
                return (["<result>…</result> on stdout, read into Jamf Pro inventory"] + analysis.outputs)
                    .joined(separator: "\n")
            }
            return analysis.outputs.isEmpty ? "None (stdout only)" : analysis.outputs.joined(separator: "\n")
        case .deployment:
            if kind == .extensionAttribute {
                return "Jamf Pro computer extension attribute (Input Type: Script, Data Type: \(dataType.rawValue)). "
                    + "Runs as root on every inventory update (recon)."
            }
            let when: String = switch trigger {
            case .recurringCheckIn: "triggered at recurring check-in"
            case .login: "triggered at login"
            case .startup: "triggered at startup"
            case .enrolmentComplete: "triggered at enrolment complete"
            case .selfService: "made available in Self Service"
            case .customEvent: "triggered by the custom event \"\(customEvent.trimmed)\""
            case .manual: "run manually (sudo jamf policy -id <ID>)"
            }
            var text = "Jamf Pro policy, \(when), \(frequency.rawValue.lowercased()). Runs as root."
            if analysis.usesConsoleUser { text += " Parts run as the console user (launchctl asuser)." }
            return text
        case .requirements:
            var lines = ["\(minimumOS) or later"]
            lines.append(analysis.checksForRoot ? "Root privileges (checked by the script)"
                                                : "Root privileges (Jamf Pro runs scripts as root)")
            if !analysis.requiredBinaries.isEmpty { lines.append("Uses: " + analysis.requiredBinaries.joined(separator: ", ")) }
            if !analysis.optionalBinaries.isEmpty { lines.append("Optional: " + analysis.optionalBinaries.joined(separator: ", ")) }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Result

    var header: ScriptHeader {
        ScriptHeader(scriptName: fileName, description: descriptionText.trimmed, author: author.trimmed,
                     version: version, created: created, updated: "\(HeaderDate.today) by \(updatedBy.trimmed)",
                     output: text(for: .output), deployment: text(for: .deployment),
                     parameters: parameters.filter { !$0.key.trimmed.isEmpty },
                     sections: sections.filter { !$0.key.trimmed.isEmpty },
                     requirements: text(for: .requirements),
                     exitCodes: exitCodes.filter { !$0.key.trimmed.isEmpty },
                     disclaimer: includeDisclaimer ? disclaimerText.trimmed : "",
                     changeLog: changeLog)
    }

    var rendered: String { HeaderRenderer.apply(header, to: split, language: language) }

    /// Line count of the new header, used to highlight it in the preview.
    var headerLineCount: Int {
        split.preamble.count + HeaderRenderer.commentBlock(header, language: language).count
    }

    /// Fields the user should confirm before saving, as the skill asks.
    var checks: [String] {
        var items: [String] = []
        if url == nil, jamfSource == nil { items.append("The file name \"\(fileName)\" was guessed. Check Script Name.") }
        if descriptionText.trimmed.isEmpty { items.append("Add a description of what the script does and why.") }
        if !isOverridden(.requirements) { items.append("The minimum OS (\(minimumOS)) is assumed. Confirm it.") }
        if existingVersion == nil {
            items.append("No version was found, so \(Self.assumedVersion) is assumed and this becomes \(version).")
        }
        if author == Self.unknownAuthor { items.append("No author was found, so Author is left as Unknown.") }
        let unexplained = exitCodes.filter { $0.value.trimmed.isEmpty || $0.value == ScriptAnalyzer.genericFailure }
        if !unexplained.isEmpty {
            items.append("Describe exit code \(unexplained.map(\.key).joined(separator: ", ")).")
        }
        let bare = sections.filter { $0.value.trimmed.isEmpty }
        if !bare.isEmpty { items.append("Add summaries for \(bare.count) section(s).") }
        if parameters.contains(where: { $0.value == "Custom parameter" }) {
            items.append("Give each Jamf parameter the label used in its Jamf Pro script settings.")
        }
        if kind == .script, trigger == .customEvent, customEvent.trimmed.isEmpty {
            items.append("Enter the custom event name.")
        }
        if hasHouseHeader, changeNote.trimmed.isEmpty { items.append("Describe this change for the Change Log.") }
        if split.shebang == nil, language.isShell {
            items.append("There's no shebang, so Jamf Pro runs this with /bin/sh. Info Headers won't add one.")
        }
        items += privacyWarnings
        return items
    }

    /// Emails, secrets and hostnames shouldn't be in a header unless asked for.
    private var privacyWarnings: [String] {
        let text = HeaderRenderer.content(header, width: 78).joined(separator: "\n")
        var items: [String] = []
        if text.firstMatch(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: [.caseInsensitive]) != nil {
            items.append("The header contains an email address. Remove it unless it's meant to be there.")
        }
        if text.firstMatch(#"(?:api[_ -]?key|token|password|secret|bearer)\s*[:=]"#, options: [.caseInsensitive]) != nil {
            items.append("The header looks like it contains a secret or token. Remove it.")
        }
        if text.firstMatch(#"https?://[^\s/]+\.(?:local|lan|internal|corp)\b|\b[\w-]+\.(?:local|lan|internal|corp)\b"#,
                           options: [.caseInsensitive]) != nil {
            items.append("The header contains an internal hostname. Remove it unless it's needed.")
        }
        return items
    }

    /// When the header was last written to disk in this session.
    private(set) var lastSaved: Date?
    /// The version written by the last save or push, and what the preview was straight afterwards,
    /// so the window can show "Saved" until something else changes.
    private(set) var savedVersion: String?
    private var renderedAfterSave: String?

    /// True when the last save or push is still what's on screen.
    var isUpToDate: Bool { savedVersion != nil && rendered == renderedAfterSave }

    /// The version in words for the window: "1.0.0 → 1.0.1" before saving, "1.0.1 · Saved" after.
    var versionSummary: String {
        if let savedVersion, isUpToDate { return "Version \(savedVersion) · Saved" }
        return "Version \(existingVersion ?? "\(Self.assumedVersion) (assumed)") → \(version)"
    }

    // MARK: - Saving

    /// Writes the script back to where it was opened, keeping its permissions.
    func save() throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        try commit(to: url, makeExecutable: false)
    }

    /// Finishes Save As. The header names the file, so it's written again if the name changed.
    func didSave(to newURL: URL) throws {
        url = newURL
        fileName = newURL.lastPathComponent
        try commit(to: newURL, makeExecutable: true)
    }

    /// Writes the script, then reloads it so the next change is counted from the saved version.
    private func commit(to url: URL, makeExecutable: Bool) throws {
        let text = rendered
        try Self.write(text, to: url, makeExecutable: makeExecutable)
        didSave(text)
    }

    /// Records that `text` was written to the file or pushed to Jamf Pro, ready for the next change.
    func didSave(_ text: String) {
        // Keep the Jamf Pro settings, which aren't stored in the file.
        let settings = (kind, trigger, customEvent, frequency, dataType, bump)
        rebuildsExistingHeader = UserDefaults.standard.bool(forKey: Self.rebuildKey)
        load(text)
        (kind, trigger, customEvent, frequency, dataType, bump) = settings
        lastSaved = .now
        savedVersion = parsed.version
        renderedAfterSave = rendered
        UserDefaults.standard.set(updatedBy, forKey: "updatedBy")
        UserDefaults.standard.set(minimumOS, forKey: "minimumOS")
        UserDefaults.standard.set(includeDisclaimer, forKey: "includeDisclaimer")
        if includeDisclaimer { UserDefaults.standard.set(disclaimerText, forKey: "disclaimer") }
    }

    /// Writes atomically, then puts back the file's permissions so scripts stay executable.
    static func write(_ text: String, to url: URL, makeExecutable: Bool) throws {
        let manager = FileManager.default
        let existing = (try? manager.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        try Data(text.utf8).write(to: url, options: .atomic)
        // Copies saved with Save As get the usual 755.
        let permissions = makeExecutable ? 0o755 : existing?.intValue ?? 0o755
        try? manager.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
    }
}
