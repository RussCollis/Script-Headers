import Foundation

/// The script languages Info Headers can write a header for.
enum ScriptLanguage: String, CaseIterable, Identifiable {
    case bash = "Bash"
    case zsh = "zsh"
    case sh = "sh"
    case python = "Python"
    case powerShell = "PowerShell"
    case appleScript = "AppleScript"
    case javaScript = "JavaScript"

    var id: String { rawValue }

    /// Shell languages that use `#` line comments for the header.
    var isShell: Bool { [.bash, .zsh, .sh].contains(self) }

    /// Prefixes that start a line comment in this language.
    var lineCommentPrefixes: [String] {
        switch self {
        case .bash, .zsh, .sh, .python, .powerShell: ["#"]
        case .appleScript: ["--", "#"]
        case .javaScript: ["//"]
        }
    }

    /// Opening and closing markers of the block comment used for the header, if any.
    var blockComment: (open: String, close: String)? {
        switch self {
        case .bash, .zsh, .sh: nil
        case .python: ("\"\"\"", "\"\"\"")
        case .powerShell: ("<#", "#>")
        case .appleScript: ("(*", "*)")
        case .javaScript: ("/*", "*/")
        }
    }

    /// Works out the language from the shebang first, then the file extension.
    static func detect(shebang: String?, fileName: String) -> ScriptLanguage {
        if let shebang = shebang?.lowercased() {
            if shebang.contains("zsh") { return .zsh }
            if shebang.contains("bash") { return .bash }
            if shebang.contains("python") { return .python }
            if shebang.contains("osascript") { return .appleScript }
            if shebang.contains("node") { return .javaScript }
            if shebang.contains("pwsh") { return .powerShell }
            if shebang.hasSuffix("/sh") || shebang.contains("/sh ") { return .sh }
        }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "zsh": return .zsh
        case "sh": return .sh
        case "py": return .python
        case "ps1", "psm1": return .powerShell
        case "applescript": return .appleScript
        case "js", "mjs": return .javaScript
        default: return .bash
        }
    }
}

/// What the script is used as in Jamf Pro.
enum ScriptKind: String, CaseIterable, Identifiable {
    case script = "Script"
    case extensionAttribute = "Extension Attribute"

    var id: String { rawValue }
    var symbol: String { self == .script ? "terminal" : "list.bullet.rectangle" }
}

/// When a Jamf Pro policy runs the script.
enum JamfTrigger: String, CaseIterable, Identifiable {
    case recurringCheckIn = "Recurring check-in"
    case login = "Login"
    case startup = "Startup"
    case enrolmentComplete = "Enrolment complete"
    case selfService = "Self Service"
    case customEvent = "Custom event"
    case manual = "Manual"

    var id: String { rawValue }
}

/// How often a Jamf Pro policy runs.
enum ExecutionFrequency: String, CaseIterable, Identifiable {
    case oncePerComputer = "Once per computer"
    case oncePerUserPerComputer = "Once per user per computer"
    case oncePerUser = "Once per user"
    case daily = "Once every day"
    case weekly = "Once every week"
    case monthly = "Once every month"
    case ongoing = "Ongoing"

    var id: String { rawValue }
}

/// Jamf Pro extension attribute data types.
enum EADataType: String, CaseIterable, Identifiable {
    case string = "String"
    case integer = "Integer"
    case date = "Date"

    var id: String { rawValue }
}

/// How much the version moves when an existing header is updated.
enum VersionBump: String, CaseIterable, Identifiable {
    case patch = "Patch"
    case minor = "Minor"
    case major = "Major"

    var id: String { rawValue }

    var help: String {
        switch self {
        case .patch: "Fixes"
        case .minor: "New features or sections"
        case .major: "Breaking changes, such as a renamed output path or changed parameters"
        }
    }

    /// Bumps a MAJOR.MINOR.PATCH version; shorter versions are padded with zeros.
    func apply(to version: String) -> String {
        var parts = version.split(separator: ".").map { Int($0) ?? 0 }
        while parts.count < 3 { parts.append(0) }
        switch self {
        case .patch: parts[2] += 1
        case .minor: parts[1] += 1; parts[2] = 0
        case .major: parts[0] += 1; parts[1] = 0; parts[2] = 0
        }
        return parts.prefix(3).map(String.init).joined(separator: ".")
    }
}

/// A two-column header row: a parameter, section or exit code and what it means.
struct HeaderRow: Identifiable, Hashable {
    let id = UUID()
    var key: String
    var value: String
}

/// One line of the header's Change Log.
struct ChangeLogEntry: Identifiable, Hashable {
    let id = UUID()
    var version: String
    var date: String
    var author: String
    var note: String
}

/// Everything that goes into a rendered header.
struct ScriptHeader {
    var scriptName = ""
    var description = ""
    var author = ""
    var version = ""
    var created = ""
    var updated = ""
    var output = ""
    var deployment = ""
    var parameters: [HeaderRow] = []
    var sections: [HeaderRow] = []
    var requirements = ""
    var exitCodes: [HeaderRow] = []
    /// Optional "provided as is" notice; left out when empty.
    var disclaimer = ""
    var changeLog: [ChangeLogEntry] = []
}

enum HeaderDate {
    private static let iso: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static var today: String { iso.string(from: .now) }

    /// Converts `dd/MM/yyyy`, `dd.MM.yyyy` or `dd-MM-yyyy` dates to ISO; anything else is returned as is.
    /// Dates are read the British way unless that's impossible, e.g. US-style `08.21.2025`.
    static func normalise(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.firstMatch(#"^\d{4}-\d{2}-\d{2}$"#) != nil { return trimmed }
        if let parts = trimmed.firstMatch(#"^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$"#),
           var day = Int(parts[1]), var month = Int(parts[2]) {
            if month > 12, day <= 12 { swap(&day, &month) }
            guard (1...12).contains(month), (1...31).contains(day) else { return trimmed }
            return String(format: "%@-%02d-%02d", parts[3], month, day)
        }
        return trimmed
    }
}

extension String {
    /// Capture groups of the first match of `pattern` (index 0 is the whole match).
    func firstMatch(_ pattern: String, options: NSRegularExpression.Options = []) -> [String]? {
        allMatches(pattern, options: options).first
    }

    /// Capture groups of every match of `pattern`; groups that didn't take part are empty strings.
    func allMatches(_ pattern: String, options: NSRegularExpression.Options = []) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let text = self as NSString
        return regex.matches(in: self, range: NSRange(location: 0, length: text.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : text.substring(with: range)
            }
        }
    }

    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
