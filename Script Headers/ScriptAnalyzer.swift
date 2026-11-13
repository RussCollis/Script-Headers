import Foundation

/// What a script does, read from its code so the header isn't guessed.
struct ScriptAnalysis {
    var exitCodes: [HeaderRow] = []
    /// Exit codes whose meaning couldn't be read from a nearby message.
    var unexplainedExitCodes: [String] = []
    var parameters: [HeaderRow] = []
    var sections: [HeaderRow] = []
    var outputs: [String] = []
    var results: [String] = []
    var requiredBinaries: [String] = []
    var optionalBinaries: [String] = []
    var usesConsoleUser = false
    var checksForRoot = false
    var reportsResult = false
    var settings: [HeaderRow] = []
    var usesEval = false
    var labelCount = 0
}

enum ScriptAnalyzer {
    /// Meaning used when no message explains an exit code.
    static let genericFailure = "Error"

    static func analyse(_ body: String, language: ScriptLanguage) -> ScriptAnalysis {
        let lines = body.components(separatedBy: "\n")
        let code = codeOnly(lines, language: language)
        let codeText = code.joined(separator: "\n")
        let variables = assignments(in: code)

        var analysis = ScriptAnalysis()
        analysis.reportsResult = body.contains("<result>")
        analysis.usesConsoleUser = codeText.firstMatch(#"launchctl\s+asuser|sudo\s+-u\s|stat\s+-f\s*%?Su\s+/dev/console|ConsoleUser"#) != nil
        analysis.checksForRoot = codeText.firstMatch(#"\$EUID|\$\(id -u\)|`id -u`|os\.geteuid\(\)"#) != nil
        (analysis.exitCodes, analysis.unexplainedExitCodes) = exitCodes(lines, language: language)
        analysis.parameters = parameters(code, language: language)
        analysis.sections = sections(lines, language: language)
        analysis.outputs = outputs(codeText, variables: variables)
        analysis.results = results(code, variables: allAssignments(in: code))
        // Paths held in variables are resolved, so `[[ -f "$BINARY_PATH" ]]` is seen as a check for the tool.
        (analysis.requiredBinaries, analysis.optionalBinaries) = binaries(resolve(codeText, variables), language: language)
        analysis.settings = settings(in: lines, language: language)
        analysis.usesEval = codeText.firstMatch(#"(?:^|[\s;&|])eval\s+"#) != nil
        let caseLabels = codeText.allMatches(#"^\s*([a-z0-9_.-]+)\)\s*$"#, options: [.anchorsMatchLines])
        if caseLabels.count > 10 {
            analysis.labelCount = caseLabels.count
        }
        return analysis
    }

    // MARK: - Code

    /// Lines with comments removed, so commented-out code isn't documented.
    private static func codeOnly(_ lines: [String], language: ScriptLanguage) -> [String] {
        lines.filter { line in
            let trimmed = line.trimmed
            return !language.lineCommentPrefixes.contains { trimmed.hasPrefix($0) }
        }
    }

    /// Simple `name="value"` assignments, used to resolve paths such as `"$logFile"`.
    private static func assignments(in code: [String]) -> [String: String] {
        var values: [String: String] = [:]
        for line in code {
            if let parts = line.firstMatch(#"^\s*(?:local\s+|export\s+|readonly\s+|declare\s+(?:-\w+\s+)?)?([A-Za-z_]\w*)=["']?([^"' \s;`]+)["']?\s*(?:#.*)?$"#) {
                values[parts[1]] = parts[2]
            }
        }
        return values
    }

    private static func resolve(_ text: String, _ variables: [String: String]) -> String {
        var result = text
        for _ in 0..<3 {
            for match in result.allMatches(#"\$\{?([A-Za-z_]\w*)\}?"#) {
                if let value = variables[match[1]] { result = result.replacingOccurrences(of: match[0], with: value) }
            }
        }
        return result
    }

    // MARK: - Exit codes

    private static func exitCodes(_ lines: [String], language: ScriptLanguage) -> ([HeaderRow], [String]) {
        let pattern = switch language {
        case .python: #"\b(?:sys\.)?exit\(\s*(\d+)\s*\)"#
        case .javaScript: #"\bprocess\.exit\(\s*(\d+)\s*\)"#
        default: #"(?:^|[\s;&|{(])exit\s+(\d+)\b"#
        }
        // Each code can be used for several different failures, so every distinct reason is kept, in order.
        var reasons: [Int: [String]] = [:]
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmed
            if language.lineCommentPrefixes.contains(where: { trimmed.hasPrefix($0) }) { continue }
            for match in line.allMatches(pattern) {
                guard let code = Int(match[1]) else { continue }
                let reason = code == 0 ? "Success" : exitReason(at: index, in: lines, language: language) ?? genericFailure
                if !(reasons[code] ?? []).contains(reason) { reasons[code, default: []].append(reason) }
            }
        }
        var meanings: [Int: String] = [:]
        for (code, list) in reasons {
            // A generic "Error" only stays when nothing better explains the code.
            let known = list.filter { $0 != genericFailure }
            meanings[code] = known.isEmpty ? genericFailure : known.joined(separator: "; ")
        }
        // 0 is only listed for scripts that call exit at all; a script that just ends needs no table.
        if !meanings.isEmpty { meanings[0] = meanings[0] ?? "Success" }
        let rows = meanings.keys.sorted().map { HeaderRow(key: String($0), value: meanings[$0] ?? "") }
        let unexplained = rows.filter { $0.value == genericFailure }.map(\.key)
        return (rows, unexplained)
    }

    /// The message printed or the comment written just before an `exit`, used as its meaning.
    /// Why the exit on line `index` happens: a comment or message next to it, or the function it is in when
    /// that function shows usage or help text. Nil when nothing nearby says.
    static func exitReason(at index: Int, in lines: [String], language: ScriptLanguage) -> String? {
        if let reason = reason(for: index, in: lines) { return reason }
        if let function = enclosingFunction(of: index, in: lines, language: language),
           function.firstMatch(#"(?i)^(?:show_?)?(?:usage|help)$"#) != nil {
            return "Usage text shown (help requested)"
        }
        return nil
    }

    /// The name of the shell function that line `index` is inside, if any. A function ends at a `}` in
    /// the first column, so code after it is at the top level again.
    private static func enclosingFunction(of index: Int, in lines: [String], language: ScriptLanguage) -> String? {
        guard language.isShell else { return nil }
        for line in lines[..<index].reversed() {
            if line.hasPrefix("}") { return nil }
            if let parts = line.firstMatch(#"^(?:function\s+([A-Za-z_][\w:.-]*)|([A-Za-z_][\w:.-]*)\s*\(\s*\))"#) {
                return parts[1].isEmpty ? parts[2] : parts[1]
            }
        }
        return nil
    }

    private static func reason(for index: Int, in lines: [String]) -> String? {
        if let comment = lines[index].firstMatch(#"exit\s+\d+\s*;?\s*#\s*(.+)$"#)?[1] {
            return clean(comment)
        }
        let message = #"(?:echo|printf|print|log\w*|Write-(?:Host|Output|Error|Warning)|console\.(?:log|error)|logger|die|fail\w*|error\w*|warn\w*)\b[^"'\n]*?["']([^"'\n]{4,})["']"#
        // Same line first (e.g. `|| { echo "…"; exit 1; }`), then up to three lines above.
        for offset in 0...3 where index - offset >= 0 {
            let line = lines[index - offset]
            if offset > 0, line.firstMatch(#"(?:^|[\s;])exit\s+\d+"#) != nil { break }
            // A heredoc's closing word (e.g. EOF) means the lines above are its text, not messages.
            if offset > 0, line.firstMatch(#"^[A-Z_]+$"#) != nil { break }
            if let text = line.allMatches(message, options: [.caseInsensitive]).last?[1], let cleaned = clean(text) {
                return cleaned
            }
        }
        return nil
    }

    static func clean(_ text: String) -> String? {
        var result = text
            .replacingOccurrences(of: #"^\s*(?:\[?(?:ERROR|FATAL|WARN(?:ING)?|FAIL(?:ED)?)?\]?\s*[:\-\x{2013}]?\s*)"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\n|\t"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .:;!-\u{2013}"))
        guard result.count >= 3 else { return nil }
        if result.count > 60 { result = String(result.prefix(57)).trimmed + "…" }
        return result.prefix(1).uppercased() + result.dropFirst()
    }

    // MARK: - Settings

    /// Top-level configuration variables and their values/meanings.
    private static func settings(in lines: [String], language: ScriptLanguage) -> [HeaderRow] {
        var items: [HeaderRow] = []
        var seen = Set<String>()
        let pattern = #"^\s*(?:local\s+|export\s+|readonly\s+|declare\s+(?:-\w+\s+)?)?([A-Z][A-Z0-9_]{2,})\s*=\s*["']?([^"'\s;`]+)?["']?\s*(?:#\s*(.+))?$"#

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmed
            if language.lineCommentPrefixes.contains(where: { trimmed.hasPrefix($0) }) { continue }
            guard let parts = line.firstMatch(pattern) else { continue }
            let key = parts[1]
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let value = parts[2].isEmpty ? "\"\"" : parts[2]
            var meaning = parts[3].trimmed
            if meaning.isEmpty {
                if index > 0 {
                    let prev = lines[index - 1].trimmed
                    if let prefix = language.lineCommentPrefixes.first(where: { prev.hasPrefix($0) }) {
                        let text = String(prev.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " -#"))
                        if !text.isEmpty { meaning = text }
                    }
                }
            }
            if meaning.isEmpty {
                meaning = defaultSettingMeaning(for: key, value: value)
            }
            items.append(HeaderRow(key: key, value: "\(value)||||\(meaning)"))
        }
        return items
    }

    static func defaultSettingMeaning(for key: String, value: String) -> String {
        switch key {
        case "DEBUG": return value == "0" ? "Production mode" : "Debug mode"
        case "NOTIFY": return value == "success" ? "Notify the user on success" : (value == "silent" ? "Silent mode" : humanise(value))
        case "BLOCKING_PROCESS_ACTION":
            return value == "tell_user" ? "Tell the user to quit a running app, then ask the app to quit" : humanise(value)
        case "PROMPT_TIMEOUT": return value == "86400" ? "Wait up to 24 hours for an answer" : "Timeout in seconds"
        case "LOGO": return value == "jamf" ? "Jamf icon in dialogs" : "\(value) icon in dialogs"
        case "IGNORE_APP_STORE_APPS": return value == "no" ? "Leave App Store / VPP apps alone" : humanise(value)
        case "INSTALL": return value == "force" ? "Reinstall even when the version matches" : humanise(value)
        case "REOPEN": return value == "yes" ? "Reopen the app after install" : humanise(value)
        case "LOGGING": return value == "INFO" ? "Normal log level" : (value == "DEBUG" ? "Verbose log level" : humanise(value))
        default: return humanise(key)
        }
    }

    // MARK: - Jamf parameters

    private static func parameters(_ code: [String], language: ScriptLanguage) -> [HeaderRow] {
        let reference = language == .python ? #"sys\.argv\[\s*(\d+)\s*\]"# : #"\$\{?(\d+)\}?"#
        var labels: [Int: String] = [:]
        for line in code {
            // In shell, `$6` inside single quotes is an awk or sed field, such as awk '{ print $6 }',
            // not a Jamf parameter, so single-quoted text is ignored.
            let searched = language.isShell ? line.replacingOccurrences(of: #"'[^']*'"#, with: "''", options: .regularExpression) : line
            for match in searched.allMatches(reference) {
                guard let number = Int(match[1]) else { continue }
                // $1–$3 are only Jamf's when read at the top level; inside functions they are arguments.
                let isTopLevelAssignment = line.firstMatch(#"^[A-Za-z_]\w*="#) != nil
                guard (4...11).contains(number) || (number == 3 && isTopLevelAssignment) else { continue }
                let label = parameterLabel(line, number: number)
                if labels[number] == nil || labels[number] == "Custom parameter" { labels[number] = label }
            }
        }
        return labels.keys.sorted().map { HeaderRow(key: "$\($0)", value: labels[$0] ?? "") }
    }

    private static func parameterLabel(_ line: String, number: Int) -> String {
        if number == 3 { return "Username of the logged-in user (passed by Jamf Pro)" }
        if let comment = line.firstMatch(#"#\s*(.+)$"#)?[1], let cleaned = clean(comment) { return cleaned }
        if let name = line.firstMatch(#"^\s*(?:local\s+|export\s+|readonly\s+)?([A-Za-z_]\w*)\s*="#)?[1] {
            return humanise(name)
        }
        return "Custom parameter"
    }

    /// Turns `installerURL` or `APP_NAME` into "Installer URL" or "App name".
    private static func humanise(_ name: String) -> String {
        let spaced = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .trimmed
        let words = spaced.split(separator: " ").enumerated().map { index, word -> String in
            if word.count > 1, word == word.uppercased(), word.contains(where: \.isLowercase) == false,
               name.contains(where: \.isLowercase) { return String(word) }  // keep acronyms in camelCase names
            let lower = word.lowercased()
            return index == 0 ? lower.prefix(1).uppercased() + lower.dropFirst() : lower
        }
        return words.joined(separator: " ")
    }

    // MARK: - Sections

    /// Section banners in the code, each with the functions defined under it. Scripts without
    /// banners list their functions instead.
    private static func sections(_ lines: [String], language: ScriptLanguage) -> [HeaderRow] {
        let functionList = functions(lines, language: language)
        let banners = sectionBanners(lines, language: language)
        guard !banners.isEmpty else {
            return functionList.map { HeaderRow(key: $0.name, value: $0.summary) }
        }
        return banners.enumerated().map { offset, banner in
            let end = offset + 1 < banners.count ? banners[offset + 1].line : lines.count
            let names = functionList.filter { $0.line > banner.line && $0.line < end }.map(\.name)
            var summary = banner.summary
            if !names.isEmpty {
                summary += (summary.isEmpty ? "" : ". ") + "Functions: " + names.joined(separator: ", ")
            }
            return HeaderRow(key: banner.title, value: summary)
        }
    }

    /// Finds section banners:
    ///
    ///     # --------------------------------------------------
    ///     # Helpers
    ///     # --------------------------------------------------
    ///
    /// as well as one-line `# ---- Helpers ----`, `# MARK: Helpers` and `# Section: Helpers` markers.
    /// Any extra comment lines inside a banner become its summary.
    private static func sectionBanners(_ lines: [String], language: ScriptLanguage) -> [(line: Int, title: String, summary: String)] {
        let comment = language.lineCommentPrefixes.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let ruler = #"^\s*(?:"# + comment + #")+\s*[-=#*~_]{5,}\s*$"#
        let oneLine = #"^\s*(?:"# + comment + #")+\s*(?:MARK:\s*-?\s*(.+?)|[-=#*]{3,}\s*([^-=#*\s].*?)\s*[-=#*]{3,}|Section:\s*(.+?))\s*$"#

        func text(of line: String) -> String? {
            let trimmed = line.trimmed
            guard let prefix = language.lineCommentPrefixes.first(where: { trimmed.hasPrefix($0) }) else { return nil }
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " #/"))
        }

        var banners: [(line: Int, title: String, summary: String)] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.firstMatch(ruler) != nil {
                // Collect the comment lines up to the closing ruler.
                var inner: [String] = []
                var cursor = index + 1
                while cursor < lines.count, lines[cursor].firstMatch(ruler) == nil, let text = text(of: lines[cursor]) {
                    if !text.isEmpty { inner.append(text) }
                    cursor += 1
                }
                if cursor < lines.count, lines[cursor].firstMatch(ruler) != nil, let title = inner.first,
                   inner.count <= 6, !title.lowercased().hasPrefix("shellcheck") {
                    let summary = inner.dropFirst().joined(separator: " ")
                    banners.append((index, title.trimmingCharacters(in: CharacterSet(charactersIn: " :-")),
                                    clean(summary) ?? ""))
                    index = cursor + 1
                    continue
                }
            } else if let parts = line.firstMatch(oneLine) {
                let title = [parts[1], parts[2], parts[3]].first { !$0.isEmpty } ?? ""
                if !title.isEmpty { banners.append((index, title, "")) }
            }
            index += 1
        }
        return banners
    }

    /// Function definitions with the comment or docstring that describes them.
    private static func functions(_ lines: [String], language: ScriptLanguage) -> [(line: Int, name: String, summary: String)] {
        let function = switch language {
        case .bash, .zsh, .sh: #"^\s*(?:function\s+([A-Za-z_][\w:.-]*)\s*(?:\(\))?|([A-Za-z_][\w:.-]*)\s*\(\))\s*\{?\s*$"#
        case .python: #"^(?:async\s+)?(?:def|class)\s+(\w+)"#
        case .powerShell: #"^\s*function\s+([\w-]+)"#
        case .javaScript: #"^\s*(?:export\s+)?(?:async\s+)?function\s+(\w+)|^\s*(?:const|let)\s+(\w+)\s*=\s*(?:async\s*)?\("#
        case .appleScript: #"^\s*(?:on|to)\s+(\w+)\s*\("#
        }
        return lines.indices.compactMap { index in
            guard let parts = lines[index].firstMatch(function, options: [.caseInsensitive]) else { return nil }
            let name = parts.dropFirst().first { !$0.isEmpty } ?? ""
            guard !name.isEmpty else { return nil }
            return (index, name, summary(above: index, in: lines, language: language) ?? "")
        }
    }

    /// The comment directly above a function, or the first line of a Python docstring inside it.
    private static func summary(above index: Int, in lines: [String], language: ScriptLanguage) -> String? {
        var comments: [String] = []
        var cursor = index - 1
        while cursor >= 0 {
            let trimmed = lines[cursor].trimmed
            guard let prefix = language.lineCommentPrefixes.first(where: { trimmed.hasPrefix($0) }) else { break }
            // A ruler means the comments above belong to a section banner, not this function.
            if trimmed.firstMatch(#"[-=#*~_]{5,}\s*$"#) != nil { break }
            let text = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " #/-=*"))
            // Lint directives such as `# shellcheck disable=…` aren't descriptions.
            if !text.isEmpty, !text.lowercased().hasPrefix("shellcheck") { comments.insert(text, at: 0) }
            cursor -= 1
        }
        if let first = comments.first(where: { $0.firstMatch(#"^[A-Za-z]"#) != nil }) {
            return clean(first.components(separatedBy: ". ").first ?? first)
        }
        if language == .python, index + 1 < lines.count,
           let doc = lines[index + 1].firstMatch(#"^\s*[rR]?(?:"""|''')\s*(.+?)\s*(?:"""|''')?\s*$"#)?[1] {
            return clean(doc)
        }
        return nil
    }

    // MARK: - Output

    private static func outputs(_ code: String, variables: [String: String]) -> [String] {
        var files: [String] = []
        let patterns = [
            #"(?<![0-9&<>=])>>?\s*["']?([^\s"';|&)<>]+)"#,          // redirects
            #"\btee\s+(?:-a\s+)?["']?([^\s"';|&)]+)"#,
            #"\btouch\s+["']?([^\s"';|&)]+)"#,
            #"PlistBuddy\b.*?-c\s+["'](?:Set|Add|Delete|Merge)[^"']*["']\s+["']?([^\s"';|&)]+)"#,
            #"\bplutil\s+-(?:replace|insert|remove|convert)\b.*\s["']?(/[^"'\s;| &)]+)"#,
            #"\bopen\(\s*["']([^"']+)["']\s*,\s*["'][wax]"#,       // Python
            #"(?:Out-File|Set-Content|Add-Content)\b[^\n]*?["']([^"']+)["']"#,  // PowerShell
        ]
        for pattern in patterns {
            for match in code.allMatches(pattern, options: [.caseInsensitive]) {
                let path = resolve(match[1], variables)
                guard path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix("$HOME"),
                      !path.hasPrefix("/dev/"), path.firstMatch(#"^[\w~$/.\-{}@ ]+$"#) != nil else { continue }
                files.append(path)
            }
        }
        for match in code.allMatches(#"\bdefaults\s+write\s+["']?([^"'\s]+)"#) {
            let domain = resolve(match[1], variables)
            files.append(domain.hasPrefix("/") ? (domain.hasSuffix(".plist") ? domain : domain + ".plist")
                                               : "Preferences for \(domain) (defaults write)")
        }

        var actions: [String] = []
        if code.firstMatch(#"\bjamf\s+recon\b"#) != nil { actions.append("Updates Jamf Pro inventory (jamf recon)") }
        for match in code.allMatches(#"\bjamf\s+policy\s+-(?:event|trigger)\s+["']?([\w.$-]+)"#) {
            actions.append("Calls the Jamf Pro policy event \"\(resolve(match[1], variables))\"")
        }
        if code.firstMatch(#"\blaunchctl\s+(?:load|bootstrap)\b"#) != nil { actions.append("Loads launchd jobs") }
        if code.firstMatch(#"\binstaller\s+-pkg\b"#) != nil { actions.append("Installs packages (installer)") }
        if code.firstMatch(#"\bsoftwareupdate\s+(?:-i|--install)\b"#) != nil { actions.append("Installs software updates") }
        if code.firstMatch(#"\bprofiles\s+(?:install|remove|-R|-I)\b"#) != nil { actions.append("Installs or removes configuration profiles") }
        if code.firstMatch(#"\brm\s+-\w*[rf]"#) != nil { actions.append("Removes files") }

        var seen = Set<String>()
        return (files + actions).filter { seen.insert($0).inserted }.prefix(10).map { $0 }
    }

    /// The values an extension attribute can report. `<result>$result</result>` lists every value assigned
    /// to `result`, and a command substitution is shown as "Output of a command".
    private static func results(_ code: [String], variables: [String: [String]]) -> [String] {
        var items: [String] = []
        func add(_ item: String) {
            if !item.isEmpty, !items.contains(item) { items.append(item) }
        }
        for line in code {
            for match in line.allMatches(#"<result>(.*?)</result>"#) {
                let trimmed = match[1].trimmed
                if let name = trimmed.firstMatch(#"^\$\{?([A-Za-z_]\w*)\}?$"#)?[1], let values = variables[name] {
                    values.forEach(add)
                } else if trimmed.hasPrefix("`") || trimmed.hasPrefix("$(") {
                    add("Output of a command")
                } else {
                    add(trimmed)
                }
            }
        }
        return items
    }

    /// Every value given to each variable, e.g. `result="Not Installed"` in each branch of an if.
    private static func allAssignments(in code: [String]) -> [String: [String]] {
        var values: [String: [String]] = [:]
        for line in code {
            guard let parts = line.firstMatch(#"^\s*(?:local\s+)?([A-Za-z_]\w*)=(?:"([^"]*)"|'([^']*)'|(\S+))\s*$"#) else { continue }
            var value = [parts[2], parts[3], parts[4]].first { !$0.isEmpty } ?? ""
            if value.hasPrefix("$(") || value.hasPrefix("`") { value = "Output of a command" }
            if !(values[parts[1]] ?? []).contains(value) { values[parts[1], default: []].append(value) }
        }
        return values
    }

    // MARK: - Binaries

    /// Tools worth listing as requirements. Third-party ones are marked as such.
    private static let knownBinaries: [(name: String, thirdParty: Bool)] = [
        ("jamf", false), ("jamfHelper", false), ("osascript", false), ("defaults", false), ("launchctl", false),
        ("plutil", false), ("PlistBuddy", false), ("curl", false), ("profiles", false), ("fdesetup", false),
        ("softwareupdate", false), ("installer", false), ("pkgutil", false), ("scutil", false),
        ("sysadminctl", false), ("dscl", false), ("security", false), ("system_profiler", false), ("ioreg", false),
        ("networksetup", false), ("diskutil", false), ("tmutil", false), ("codesign", false), ("spctl", false),
        ("mdls", false), ("mdfind", false), ("sqlite3", false), ("xmllint", false), ("openssl", false),
        ("ditto", false), ("hdiutil", false), ("sw_vers", false), ("mdmclient", false), ("pmset", false),
        ("systemsetup", false), ("xattr", false), ("kickstart", false), ("jq", false),
        ("python3", true), ("dockutil", true), ("desktoppr", true), ("brew", true), ("mas", true),
        ("installomator", true), ("Installomator", true),
    ]

    private static func binaries(_ code: String, language: ScriptLanguage) -> ([String], [String]) {
        var required: [String] = []
        var optional: [String] = []
        if language == .python { required.append("python3 (not included with macOS since 12.3)") }

        func isOptional(_ name: String) -> Bool {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            return code.firstMatch(#"(?:command\s+-v|which|type\s+-p)\s+["']?"# + escaped + #"\b|-[xef]\s+["']?[^\s"']*/"# + escaped + #"["'\s\]]"#) != nil
        }

        for binary in knownBinaries where !(language == .python && binary.name == "python3") {
            let escaped = NSRegularExpression.escapedPattern(for: binary.name)
            guard code.firstMatch(#"(?<![\w.$-])"# + escaped + #"(?![\w-])"#) != nil else { continue }
            let label = binary.thirdParty ? "\(binary.name) (third-party)" : binary.name
            if isOptional(binary.name) { optional.append(label) } else { required.append(label) }
        }
        // swiftDialog's binary is called "dialog", which is too common a word to match loosely.
        if code.firstMatch(#"/usr/local/bin/dialog\b|(?:^|[\s;|&(])dialog\s+--"#, options: [.anchorsMatchLines]) != nil {
            let label = "swiftDialog (third-party, /usr/local/bin/dialog)"
            if isOptional("dialog") { optional.append(label) } else { required.append(label) }
        }
        return (required, optional)
    }
}
