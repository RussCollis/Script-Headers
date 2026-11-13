import Foundation

/// Adds plain-English comment lines above a script's code, worked out by fixed rules like the header.
///
/// Only whole new comment lines are inserted, each on its own line, so no line of code is changed,
/// moved or removed. Lines inside heredocs, multi-line strings, block comments and continued commands
/// are never touched. Code that already has a comment directly above it is left alone, which also
/// means commenting a script a second time adds nothing new.
enum ScriptCommenter {
    struct Result {
        var text: String
        /// Indexes (from 0) of the lines that were added, used to highlight them in the preview.
        var addedLines: Set<Int>
    }

    /// Comments `text`. The first `protectedLines` lines (such as a new header) are copied as they are.
    /// `exitMeanings` maps exit codes to the meanings listed in the header, e.g. "1" → "Tool missing".
    static func comment(_ text: String, language: ScriptLanguage, exitMeanings: [String: String],
                        protectedLines: Int = 0) -> Result {
        let lines = text.components(separatedBy: "\n")
        let marker = commentMarker(for: language)
        let rules = RuleSet.for(language)
        var output: [String] = []
        output.reserveCapacity(lines.count * 2)
        var added = Set<Int>()
        var scanner = CodeScanner(language: language)
        // The notes worked out for the last line of code, so a run of similar lines (e.g. several
        // echo lines) gets one comment rather than the same one repeated.
        var previousNotes: [String] = []
        var previousIsComment = false

        let groups = language.isShell ? redirectedGroups(in: lines) : [:]

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmed
            let isComment = isComment(trimmed, language: language)
            if trimmed.isEmpty { previousNotes = [] }
            if index >= protectedLines, scanner.isAtStatementStart, !trimmed.isEmpty, !isComment {
                var notes: [String]
                if let group = groups[index], group.start == index {
                    notes = ["Write everything printed in this block to \(group.target), replacing anything already in it.",
                             "The redirect is on the closing brace, so the echo lines below go to the file, not the policy log."]
                } else if groups[index] != nil, trimmed.firstMatch(#"^(?:echo|printf)\b"#) != nil {
                    // Already explained by the note on the opening brace.
                    notes = []
                } else {
                    notes = self.notes(for: trimmed, at: index, in: lines, rules: rules, language: language,
                                       exitMeanings: exitMeanings)
                }
                if index == 0, language.isShell, !line.hasPrefix("#!") {
                    notes.insert("WARNING: Missing shebang on line 1. State which interpreter this script requires (e.g. #!/bin/bash or #!/bin/zsh).", at: 0)
                }
                if !notes.isEmpty, !previousIsComment, notes != previousNotes {
                    let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                    for note in notes {
                        added.insert(output.count)
                        output.append(indent + marker + " " + note)
                    }
                }
                previousNotes = notes
            }
            previousIsComment = isComment
            output.append(line)
            scanner.consume(line)
        }
        return Result(text: output.joined(separator: "\n"), addedLines: added)
    }

    // MARK: - Notes

    /// Lines inside `{ … } > file` blocks, keyed by line, with where the block starts and the file it writes.
    private static func redirectedGroups(in lines: [String]) -> [Int: (start: Int, target: String)] {
        var groups: [Int: (start: Int, target: String)] = [:]
        for (start, line) in lines.enumerated() where line.trimmed == "{" {
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            for end in (start + 1)..<lines.count {
                let closing = lines[end]
                guard closing.hasPrefix(indent), closing.dropFirst(indent.count).first == "}" else { continue }
                if let target = closing.trimmed.firstMatch(#"^\}\s*>>?\s*("[^"]+"|'[^']+'|\S+)"#)?[1], target != "/dev/null" {
                    for index in start..<end { groups[index] = (start, target) }
                }
                break
            }
        }
        return groups
    }

    /// The comment lines for one line of code, or none when no rule says anything useful about it.
    private static func notes(for line: String, at index: Int, in lines: [String], rules: RuleSet,
                              language: ScriptLanguage, exitMeanings: [String: String]) -> [String] {
        if let function = functionNotes(for: line, at: index, in: lines, language: language) {
            return function
        }
        var notes: [String] = []
        let assigned = rules.assignment.flatMap { $0.captures(in: line)?[1] }

        if let note = rules.jamf.lazy.compactMap({ $0.note(for: line) }).first {
            notes.append(note)
        } else if let note = rules.commands.lazy.compactMap({ $0.note(for: line) }).first {
            // `currentUser=$(scutil …)` reads better as "currentUser: get the logged-in console user."
            if let assigned {
                notes.append("\(assigned): " + note.prefix(1).lowercased() + note.dropFirst())
            } else {
                notes.append(note)
            }
        } else if let note = rules.flow.lazy.compactMap({ $0.note(for: line) }).first {
            notes.append(note)
        } else if let assigned, let value = rules.assignment?.captures(in: line)?[2] {
            notes.append(assignmentNote(assigned, value: value.trimmed, language: language))
        }

        if let code = rules.exit?.captures(in: line)?[1] {
            // The reason next to this exit comes first: one code is often used for several failures, and
            // the header lists them all. The header's meaning is only used when nothing nearby says why.
            let meaning = (code == "0" ? nil : ScriptAnalyzer.exitReason(at: index, in: lines, language: language))
                ?? exitMeanings[code].flatMap { $0.trimmed.isEmpty ? nil : $0.trimmed }
                ?? (code == "0" ? "Success" : ScriptAnalyzer.genericFailure)
            if code == "0" {
                notes.append("Exit 0: Success, not an error, so the Jamf policy is marked completed.")
            } else {
                notes.append("Exit \(code): \(meaning). Jamf marks the policy as failed.")
            }
        }
        return notes
    }

    /// What a plain variable assignment holds, judged from the shape of its value.
    private static func assignmentNote(_ name: String, value: String, language: ScriptLanguage) -> String {
        let shown = language == .powerShell ? "$" + name : name
        let trimmedVal = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if name == name.uppercased() && name.count >= 3 && !name.hasPrefix("_") {
            let desc = ScriptAnalyzer.defaultSettingMeaning(for: name, value: trimmedVal)
            return "\(shown): \(desc) (default: \(value))."
        }
        if value.hasPrefix("$(") || value.hasPrefix("`") || value.hasPrefix("\"$(") {
            return "\(shown) holds the command output executed on this line."
        }
        if value.hasPrefix("(") || value.hasPrefix("[") || value.hasPrefix("@(") {
            return "\(shown) is a list of values used later in the script."
        }
        if value.firstMatch(#"^["']?(?:~|/|\$\{?HOME)"#) != nil {
            return "\(shown) holds a path used later in the script."
        }
        return "\(shown) is set here and used later in the script."
    }

    // MARK: - Functions

    /// A section banner and a summary above a function, with its arguments and return codes.
    private static func functionNotes(for line: String, at index: Int, in lines: [String],
                                      language: ScriptLanguage) -> [String]? {
        let indent = lines[index].prefix { $0 == " " || $0 == "\t" }.count
        let pattern: String = switch language {
        case .bash, .zsh, .sh: #"^(?:function\s+([A-Za-z_][\w:.-]*)|([A-Za-z_][\w:.-]*)\s*\(\s*\))"#
        case .python: #"^(?:async\s+)?def\s+(\w+)\s*\(([^)]*)"#
        case .powerShell: #"^function\s+([\w-]+)"#
        case .javaScript: #"^(?:export\s+)?(?:async\s+)?function\s*\*?\s*(\w+)|^(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s*)?(?:\([^)]*\)|\w+)\s*=>"#
        case .appleScript: #"^(?:on|to)\s+(\w+)"#
        }
        guard let match = line.firstMatch(pattern) else { return nil }
        let name = match.dropFirst().first { !$0.isEmpty && !$0.contains(",") } ?? ""
        guard !name.isEmpty else { return nil }

        if language == .appleScript {
            // `on error` starts an error handler, not a function.
            if name == "error" { return nil }
            if name == "run" { return [banner("Main handler", indent: indent), "Runs when the script starts."] }
        }

        let body = functionBody(after: index, indent: indent, in: lines, language: language)
        var summary = "\(name): \(humanise(name))."
        switch language {
        case .bash, .zsh, .sh:
            let arguments = Set(body.flatMap { $0.allMatches(#"\$\{?([1-9])\b"#).map { "$" + $0[1] } }).sorted()
            if !arguments.isEmpty { summary += " Arguments: \(arguments.joined(separator: ", "))." }
            if body.contains(where: { $0.contains("$@") || $0.contains("$*") }) { summary += " Uses all the arguments it's given." }
            let returns = Set(body.flatMap { $0.allMatches(#"\breturn\s+(\d+)"#).map { $0[1] } }).sorted()
            if !returns.isEmpty { summary += " Returns \(returns.joined(separator: " or "))." }
        case .python:
            let rawArgs = match[2].split(separator: ",")
            let cleanedArgs = rawArgs.map { piece -> String in
                let withoutDefault = piece.split(separator: "=").first.map(String.init) ?? ""
                let nameOnly = withoutDefault.split(separator: ":").first.map(String.init) ?? ""
                return nameOnly.trimmed
            }
            let arguments = cleanedArgs.filter { !$0.isEmpty && $0 != "self" && $0 != "cls" }
            if !arguments.isEmpty { summary += " Arguments: \(arguments.joined(separator: ", "))." }
            if body.contains(where: { $0.trimmed.firstMatch(#"^return\s+\S"#) != nil }) { summary += " Returns a value." }
        default:
            break
        }
        return [banner("Function: \(name)", indent: indent), summary]
    }

    /// The lines of a function, up to its closing brace, `end` or the next line indented no further.
    private static func functionBody(after index: Int, indent: Int, in lines: [String],
                                     language: ScriptLanguage) -> [String] {
        var body: [String] = []
        for line in lines.dropFirst(index + 1) {
            let trimmed = line.trimmed
            let lineIndent = line.prefix { $0 == " " || $0 == "\t" }.count
            if language == .python {
                if !trimmed.isEmpty, lineIndent <= indent { break }
            } else if language == .appleScript {
                if trimmed.hasPrefix("end"), lineIndent <= indent { break }
            } else if trimmed.hasPrefix("}"), lineIndent <= indent {
                break
            }
            body.append(line)
        }
        return body
    }

    /// `checkForRoot` or `check_for_root` → "Check for root".
    private static func humanise(_ name: String) -> String {
        let spaced = name
            .replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"[_:.-]+"#, with: " ", options: .regularExpression)
            .lowercased()
            .trimmed
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// `----- Title -----------------------------------------------------------------` padded to about 80 columns.
    private static func banner(_ title: String, indent: Int) -> String {
        let start = "----- \(title) "
        return start + String(repeating: "-", count: max(5, 78 - indent - start.count))
    }

    // MARK: - Comments

    /// The line comment marker used for the added comments.
    private static func commentMarker(for language: ScriptLanguage) -> String {
        switch language {
        case .appleScript: "--"
        case .javaScript: "//"
        default: "#"
        }
    }

    /// True for comment lines, including the first line of a block comment and the shebang.
    private static func isComment(_ trimmed: String, language: ScriptLanguage) -> Bool {
        if language.lineCommentPrefixes.contains(where: { trimmed.hasPrefix($0) }) { return true }
        if let block = language.blockComment, language != .python, trimmed.hasPrefix(block.open) { return true }
        return false
    }
}

// MARK: - Rules

/// A pattern and the comment written when it matches. `$1`, `$2`… in the template are filled with
/// the pattern's capture groups; `\$` writes a literal dollar sign.
private struct Rule {
    let regex: NSRegularExpression
    let template: String

    init?(_ pattern: String, _ template: String = "") {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        self.regex = regex
        self.template = template
    }

    func note(for line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        return regex.replacementString(for: match, in: line, offset: 0, template: template)
    }

    /// Capture groups of the first match; groups that didn't take part are empty strings.
    func captures(in line: String) -> [String]? {
        let text = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : text.substring(with: range)
        }
    }
}

/// The rules for one language, compiled once and checked in order: Jamf Pro parameters, then
/// well-known commands, then control flow, then plain assignments. Exits are noted as well.
private struct RuleSet {
    var jamf: [Rule] = []
    var commands: [Rule] = []
    var flow: [Rule] = []
    /// Captures the variable name (1) and its value (2).
    var assignment: Rule?
    /// Captures the exit code (1).
    var exit: Rule?

    static func `for`(_ language: ScriptLanguage) -> RuleSet {
        switch language {
        case .bash, .zsh, .sh: shell
        case .python: python
        case .powerShell: powerShell
        case .javaScript: javaScript
        case .appleScript: appleScript
        }
    }

    private static func rules(_ pairs: [(String, String)]) -> [Rule] {
        pairs.compactMap { Rule($0.0, $0.1) }
    }

    private static let resultNote = "Report this value to Jamf Pro inventory: extension attributes read the text between <result> tags."
    private static let printNote = "Print a message. Jamf Pro shows it in the policy log."
    private static let deleteNote = "Delete files or folders. There's no undo."

    private static let shell = RuleSet(
        jamf: rules([
            (#"^(?:local\s+|export\s+|readonly\s+)?([A-Za-z_]\w*)=["']?\$\{?([4-9]|1[01])\}?"#,
             #"$1 comes from Jamf Pro parameter \$$2, set in the policy's script options."#),
            (#"^(?:local\s+|export\s+|readonly\s+)?([A-Za-z_]\w*)=["']?\$\{?3\}?["']?\s*$"#,
             #"$1 is the logged-in username, which Jamf Pro passes as \$3."#),
            (#"^(?:local\s+|export\s+|readonly\s+)?([A-Za-z_]\w*)=["']?\$\{?2\}?["']?\s*$"#,
             #"$1 is the target computer name, which Jamf Pro passes as \$2."#),
            (#"^(?:local\s+|export\s+|readonly\s+)?([A-Za-z_]\w*)=["']?\$\{?1\}?["']?\s*$"#,
             #"$1 is the target drive mount point, which Jamf Pro passes as \$1."#),
        ]),
        commands: rules([
            (#"ConsoleUser|stat\s+-f\s*%?Su\s+/dev/console"#,
             #"Who is sitting at the Mac right now? Jamf runs scripts as root, so \$USER would just say root."#),
            (#"launchctl\s+asuser"#, "Platform quirk: Run this inside the logged-in user's GUI console session instead of as root."),
            (#"\bsudo\s+-u\s"#, "Run this command as another user instead of root."),
            (#"\$EUID|\$\(id -u\)|`id -u`"#, "Check the script is running with root privileges (required by Jamf Pro policies)."),
            (#"(?:^|[\s;&|(])eval\s+"#, "WARNING: Overrides are run through eval. Only trusted admin-set Jamf parameters should be used."),
            (#"^\s*shift\b"#, "Jamf sends '/', computer name and user name first; shift these off automatically."),
            (#"<result>"#, resultNote),
            (#"\bjamf\s+recon\b"#, "Send an inventory update to Jamf Pro."),
            (#"\bjamf\s+policy\b"#, "Run Jamf Pro policies (with -event, only the ones on that custom trigger)."),
            (#"jamfHelper"#, "Show a message window to the user with jamfHelper."),
            (#"swiftDialog|/usr/local/bin/dialog\b"#, "Show a window or prompt to the user with swiftDialog."),
            (#"\bosascript\b"#, "Run AppleScript, usually to show a dialog or interact with GUI apps."),
            (#"\bdefaults\s+write\b"#, "Write a preference setting using defaults."),
            (#"\bdefaults\s+read\b"#, "Read a preference setting using defaults."),
            (#"\bdefaults\s+delete\b"#, "Remove a preference setting using defaults."),
            (#"PlistBuddy"#, "Read or edit a property list with PlistBuddy."),
            (#"\bplutil\b"#, "Read, check or convert a property list with plutil."),
            (#"\bcurl\b"#, "Download a file or call an API endpoint with curl."),
            (#"\binstaller\s+-pkg\b"#, "Install a package using macOS installer."),
            (#"\bhdiutil\s+attach\b"#, "Mount a disk image (.dmg)."),
            (#"\bhdiutil\s+detach\b"#, "Unmount the disk image."),
            (#"\bsoftwareupdate\b"#, "Check for or install macOS updates."),
            (#"\bsw_vers\b"#, "Read the macOS system version."),
            (#"\bsystem_profiler\b"#, "Read hardware or system details with system_profiler."),
            (#"\bsysctl\b"#, "Read a kernel or hardware setting with sysctl."),
            (#"\bioreg\b"#, "Read hardware details from the I/O Registry."),
            (#"\bfdesetup\b"#, "Check or manage FileVault status with fdesetup."),
            (#"\bprofiles\s"#, "Check or manage configuration profiles."),
            (#"\bdscl\b"#, "Look up or modify accounts in OpenDirectory using dscl."),
            (#"\bdiskutil\b"#, "Check or manage disks and APFS volumes."),
            (#"\bpkgutil\b"#, "Query or forget installed package receipts."),
            (#"\bcodesign\b"#, "Verify an application's code signature and Team ID."),
            (#"\bspctl\b"#, "Check Gatekeeper's assessment of an application."),
            (#"\b(?:killall|pkill)\b"#, "Quit a running process."),
            (#"\bpgrep\b"#, "Check whether a matching process is currently running."),
            (#"\blaunchctl\s+(?:bootstrap|load|kickstart)\b"#, "Start or load a launch daemon or agent."),
            (#"\blaunchctl\s+(?:bootout|unload|remove)\b"#, "Stop or unload a launch daemon or agent."),
            (#"\bexec\s*>\s*>\(\s*tee\b"#, "Send all script output to both the log file and standard output."),
            (#"\btee\b"#, "Write command output to a file while also displaying it on screen."),
            (#"^set\s+[-+]\w"#, "Shell options: -e stops on errors, -u on unset variables, -o pipefail fails if any step fails, -x prints commands."),
            (#"^trap\s"#, "Set a signal trap to run clean-up tasks when the script exits or receives an interrupt."),
            (#"^(?:source|\.)\s+\S"#, "Source functions and variable declarations from an external script file."),
            (#"\brm\s+-\w*[rR]"#, deleteNote),
            (#"(?:^|[\s;&|(])rm\s"#, "Delete a file. There's no undo."),
            (#"\bmkdir\s+-p\b"#, "Create directory path, creating intermediate parent directories as needed."),
            (#"(?:^|[\s;&|(])mkdir\s"#, "Create a directory."),
            (#"\bchown\b"#, "Set user/group ownership permissions."),
            (#"\bchmod\b"#, "Set POSIX file permissions (mode)."),
            (#"\bditto\b"#, "Copy files preserving permissions, resource forks, and extended attributes."),
            (#"(?:^|[\s;&|(])cp\s"#, "Copy files or directories."),
            (#"(?:^|[\s;&|(])mv\s"#, "Move or rename a file or directory."),
            (#"\bln\s+-s"#, "Create a symbolic link."),
            (#"(?:^|[\s;&|(])(?:tar|unzip|zip)\s"#, "Extract or create an archive."),
            (#"\bsleep\s+(\d+)"#, "Pause script execution for $1 second(s)."),
            (#"\b(?:shutdown|reboot)\b"#, "Reboot or shut down the Mac."),
            (#"\blogger\b"#, "Write a message to the unified system log (syslog)."),
            (#"\bawk\b"#, "Extract specific fields or formatted text using awk."),
            (#"\bsed\b"#, "Transform or filter stream text using sed."),
            (#"\bgrep\b"#, "Search for pattern matches using grep."),
            (#"\bcut\b"#, "Extract delimited sections from text lines."),
            (#"\bxargs\b"#, "Build and execute commands from standard input."),
            (#"\bjq\b"#, "Parse and extract values from JSON structured output using jq."),
        ]),
        flow: rules([
            (#"^for\s+(\w+)\s+in\b"#, #"Repeat the block below once for each item, held in \$$1."#),
            (#"^for\s*\(\("#, "Repeat the block below, counting as it goes."),
            (#"^while\s.*\bread\b"#, "Read the input one line at a time."),
            (#"^while\s"#, "Repeat the block below while the condition is true."),
            (#"^until\s"#, "Repeat the block below until the condition is true."),
            (#"^case\s+(.+?)\s+in\b"#, "Choose what to do based on the value of $1."),
            (#"^(?:if|elif)\s+\[\[?\s+!\s+-[fe]\s+(\S+)"#, "Check whether $1 is missing."),
            (#"^(?:if|elif)\s+\[\[?\s+-[fe]\s+(\S+)"#, "Check whether $1 exists."),
            (#"^(?:if|elif)\s+\[\[?\s+!\s+-d\s+(\S+)"#, "Check whether the folder $1 is missing."),
            (#"^(?:if|elif)\s+\[\[?\s+-d\s+(\S+)"#, "Check whether the folder $1 exists."),
            (#"^(?:if|elif)\s+\[\[?\s+!\s+-x\s+(\S+)"#, "Check whether $1 is missing or can't be run."),
            (#"^(?:if|elif)\s+\[\[?\s+-x\s+(\S+)"#, "Check whether $1 can be run."),
            (#"^(?:if|elif)\s+\[\[?\s+-z\s+["']?\$(?:currentUser|consoleuser|user|loggedInUser)["']?"#, "No console user logged in (e.g. loginwindow): skip user tasks or bail out cleanly."),
            (#"^(?:if|elif)\s+\[\[?\s+-z\s+(\S+)"#, "Check whether $1 is empty."),
            (#"^(?:if|elif)\s+\[\[?\s+-n\s+(\S+)"#, "Check whether $1 has a value."),
            (#"^(?:if|elif)\s"#, "Only run the block below when this test passes."),
            (#"^(?:echo|printf)\b.*?(?<![0-9&])>>\s*("[^"]+"|'[^']+'|[^\s;&|]+)"#, "Add this text to the end of $1."),
            (#"^(?:echo|printf)\b.*?(?<![0-9&>])>(?![>&])\s*(?!/dev/null)("[^"]+"|'[^']+'|[^\s;&|]+)"#,
             "Write this text to $1, replacing anything already in it."),
            (#"^(?:echo|printf)\b"#, printNote),
        ]),
        assignment: Rule(#"^(?:local\s+|export\s+|readonly\s+|declare\s+(?:-\w+\s+)?)?([A-Za-z_]\w*)=(.*)$"#),
        exit: Rule(#"(?:^|[\s;&|{(])exit\s+(\d+)\b"#)
    )

    private static let python = RuleSet(
        commands: rules([
            (#"<result>"#, resultNote),
            (#"os\.geteuid\(\)"#, "Check the script is running with root privileges."),
            (#"subprocess\."#, "Run a shell command as a child process."),
            (#"sys\.exit\(\s*0\s*\)"#, "Exit 0: Success, not an error."),
            (#"sys\.exit\(\s*(\d+)\s*\)"#, "Exit $1: Error reported back to Jamf Pro."),
            (#"syslog\."#, "Write an entry into the unified system log."),
            (#"print\b"#, printNote),
        ]),
        flow: rules([
            (#"^for\s+(\w+)\s+in\b"#, "Repeat the block below for each item, held in $1."),
            (#"^while\s"#, "Repeat the block below while the condition holds true."),
            (#"^try:"#, "Attempt the block below and catch any errors that occur."),
            (#"^except\b"#, "Handle errors raised in the try block."),
            (#"^(?:if|elif)\s"#, "Only run the block below when this test passes."),
        ]),
        assignment: Rule(#"^([A-Za-z_]\w*)\s*=\s*(.*)$"#),
        exit: Rule(#"\b(?:sys\.)?exit\(\s*(\d+)\s*\)"#)
    )

    private static let powerShell = RuleSet(
        commands: rules([
            (#"Start-Process\b"#, "Start a process on the computer."),
            (#"Stop-Process\b"#, "Stop a running process."),
            (#"Get-Service\b"#, "Look up the state of a service."),
            (#"Set-ItemProperty\b"#, "Change a registry value or item setting."),
            (#"Get-ItemProperty\b"#, "Read a registry value or item setting."),
            (#"Write-(?:Host|Output)\b"#, printNote),
            (#"Write-Error\b"#, "Write an error message to standard error."),
        ]),
        flow: rules([
            (#"^foreach\s*\(\s*\$(\w+)\s+in\b"#, "Repeat the block below for each item, held in $$1."),
            (#"^while\s*\("#, "Repeat the block below while the condition holds true."),
            (#"^try\s*\{"#, "Attempt the block below and catch any errors that occur."),
            (#"^catch\b"#, "Handle errors raised in the try block."),
            (#"^(?:if|elseif)\s*\("#, "Only run the block below when this test passes."),
        ]),
        assignment: Rule(#"^\$([A-Za-z_]\w*)\s*=\s*(.*)$"#),
        exit: Rule(#"\bexit\s+(\d+)\b"#)
    )

    private static let javaScript = RuleSet(
        commands: rules([
            (#"console\.(?:log|info)\b"#, printNote),
            (#"console\.(?:error|warn)\b"#, "Print a diagnostic or error message to standard error."),
            (#"process\.exit\(\s*0\s*\)"#, "Exit 0: Success."),
            (#"process\.exit\(\s*(\d+)\s*\)"#, "Exit $1: Error status code."),
        ]),
        flow: rules([
            (#"^for\s*\(\s*(?:const|let|var)\s+(\w+)\s+of\b"#, "Repeat the block below for each item, held in $1."),
            (#"^while\s*\("#, "Repeat the block below while the condition holds true."),
            (#"^try\s*\{"#, "Attempt the block below and catch any errors that occur."),
            (#"^catch\b"#, "Handle errors raised in the try block."),
            (#"^(?:if|else\s+if)\s*\("#, "Only run the block below when this test passes."),
        ]),
        assignment: Rule(#"^(?:const|let|var)\s+([A-Za-z_]\w*)\s*=\s*(.*)$"#),
        exit: Rule(#"\bprocess\.exit\(\s*(\d+)\s*\)"#)
    )

    private static let appleScript = RuleSet(
        commands: rules([
            (#"\bdisplay\s+dialog\b"#, "Display an interactive dialog window to the user."),
            (#"\bdisplay\s+alert\b"#, "Display an alert window with icon to the user."),
            (#"\bdisplay\s+notification\b"#, "Post a macOS User Notification banner."),
            (#"\bdo\s+shell\s+script\b.*?\bwith\s+administrator\s+privileges\b"#, "Execute a shell command with root (sudo) privileges."),
            (#"\bdo\s+shell\s+script\b"#, "Execute a shell command directly from AppleScript."),
            (#"\btell\s+application\b"#, "Send Apple Events to control another application."),
        ]),
        flow: rules([
            (#"^repeat\s+with\s+(\w+)\s+in\b"#, "Repeat the block below for each item, held in $1."),
            (#"^repeat\s+while\b"#, "Repeat the block below while the condition is true."),
            (#"^repeat\s+until\b"#, "Repeat the block below until the condition is true."),
            (#"^try\b"#, "Attempt the block below and catch any errors that occur."),
            (#"^on\s+error\b"#, "Handle errors raised in the try block."),
            (#"^(?:if|else\s+if)\b"#, "Only run the block below when this condition is true."),
        ]),
        assignment: Rule(#"^(?:set|copy)\s+([A-Za-z_]\w*)\s+to\s+(.*)$"#),
        exit: Rule(#"\berror\b.*?\bnumber\s+(\d+)\b"#)
    )
}

// MARK: - Code scanner

/// Keeps track of whether the scanner is inside a heredoc, block comment, multi-line string or
/// line continuation, so comment lines are never inserted into data or mid-command.
private struct CodeScanner {
    let language: ScriptLanguage
    private(set) var isAtStatementStart = true
    private var inHeredocDelimiter: String?
    private var inBlockComment = false
    private var inMultilineStringDelimiter: String?
    private var inContinuation = false

    init(language: ScriptLanguage) { self.language = language }

    mutating func consume(_ line: String) {
        let trimmed = line.trimmed

        // Heredoc (Bash / zsh / sh)
        if let delimiter = inHeredocDelimiter {
            if trimmed == delimiter { inHeredocDelimiter = nil }
            isAtStatementStart = inHeredocDelimiter == nil
            return
        }
        if language.isShell,
           let delimiter = trimmed.firstMatch(#"<<-?\s*['"]?([A-Za-z_]\w*)['"]?\s*$"#)?[1] {
            inHeredocDelimiter = delimiter
            isAtStatementStart = false
            return
        }

        // Block comment
        if inBlockComment {
            if let close = language.blockComment?.close, trimmed.contains(close) { inBlockComment = false }
            isAtStatementStart = !inBlockComment
            return
        }
        if let block = language.blockComment, language != .python, trimmed.contains(block.open) {
            if !trimmed.contains(block.close) { inBlockComment = true }
            isAtStatementStart = !inBlockComment
            return
        }

        // Python multi-line docstring
        if language == .python {
            if let delimiter = inMultilineStringDelimiter {
                if trimmed.contains(delimiter) { inMultilineStringDelimiter = nil }
                isAtStatementStart = inMultilineStringDelimiter == nil
                return
            }
            for triple in ["\"\"\"", "'''"] where trimmed.hasPrefix(triple) {
                let rest = trimmed.dropFirst(triple.count)
                if !rest.contains(triple) { inMultilineStringDelimiter = triple }
                isAtStatementStart = inMultilineStringDelimiter == nil
                return
            }
        }

        // Line continuation: a backslash at the end of the line
        if inContinuation {
            inContinuation = trimmed.hasSuffix("\\")
            isAtStatementStart = !inContinuation
            return
        }
        if trimmed.hasSuffix("\\") {
            inContinuation = true
            isAtStatementStart = false
            return
        }

        isAtStatementStart = true
    }
}
