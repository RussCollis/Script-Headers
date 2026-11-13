import Foundation

/// A script cut into the lines that must stay first, its leading comment block and the code.
struct ScriptSplit {
    /// The shebang, plus a Python encoding line. Always kept on the first lines.
    var preamble: [String] = []
    /// Text of the leading comment block with the comment markers removed.
    var headerLines: [String] = []
    /// Lines found in the comment block that must stay in the code, such as `# shellcheck` directives.
    var directives: [String] = []
    /// Everything after the leading comment block.
    var body = ""
    /// Older headers stacked under the first one (or found in place of it), such as a `: <<'SCRIPT_INFO'`
    /// block from before the house format. Their details are merged into the new header and the blocks
    /// are removed, so the script ends up with one header.
    var olderHeaders: [[String]] = []

    var shebang: String? { preamble.first { $0.hasPrefix("#!") } }

    /// Splits `text`, treating the first comment block after the shebang as the existing header.
    init(text: String, language: ScriptLanguage) {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        if lines.first?.hasPrefix("#!") == true {
            preamble.append(lines[0])
            index = 1
        }
        if language == .python, index < lines.count,
           lines[index].firstMatch(#"^#.*coding[:=]"#) != nil {
            preamble.append(lines[index])
            index += 1
        }
        while index < lines.count, lines[index].trimmed.isEmpty { index += 1 }

        let start = index
        if language.isShell, let end = Self.takeHeredoc(lines, from: index, directives: &directives, into: &headerLines) {
            index = end
        } else if let block = language.blockComment, index < lines.count, lines[index].trimmed.hasPrefix(block.open) {
            index = Self.takeBlock(lines, from: index, block: block, language: language, into: &headerLines)
        } else {
            var comments: [String] = []
            while true {
                while index < lines.count, let text = Self.lineComment(lines[index], language: language) {
                    if Self.isDirective(lines[index], language: language) {
                        directives.append(lines[index])
                    } else {
                        comments.append(text)
                    }
                    index += 1
                }
                // Loose headers are often several comment paragraphs separated by blank lines, e.g. a
                // description, an example of the output, then the source, author and date.
                guard !comments.isEmpty, let next = Self.nextHeaderParagraph(lines, after: index, language: language) else {
                    break
                }
                comments.append("")
                index = next
            }
            // A single comment line sitting on top of code describes that code, not the script.
            let followedByCode = index < lines.count && !lines[index].trimmed.isEmpty
            if comments.count == 1, followedByCode, !HeaderParser.isStructured(comments) {
                index = start
                directives = []
            } else {
                headerLines = comments
            }
        }

        if index == start { headerLines = [] }
        if language.isShell {
            // Take in any older headers sitting directly under the first one, e.g. a tag comment such as
            // `# [KPMG] 2026` followed by a `: <<'SCRIPT_INFO'` block with Description, Author and so on.
            while let (block, end) = Self.olderHeader(lines, from: index, language: language) {
                if headerLines.isEmpty, index == start { headerLines = block } else { olderHeaders.append(block) }
                index = end
            }
        }
        lines.removeFirst(index)
        while lines.first?.trimmed.isEmpty == true { lines.removeFirst() }
        body = lines.joined(separator: "\n")
    }

    /// An older header starting at `start` (after blank lines): optional comment lines directly above a
    /// heredoc whose text has header labels. Returns its text and the line after it, or nil.
    private static func olderHeader(_ lines: [String], from start: Int, language: ScriptLanguage) -> ([String], Int)? {
        var index = start
        while index < lines.count, lines[index].trimmed.isEmpty { index += 1 }
        var leading: [String] = []
        while index < lines.count, !isDirective(lines[index], language: language),
              let text = lineComment(lines[index], language: language) {
            leading.append(text)
            index += 1
        }
        var block: [String] = []
        var directives: [String] = []
        guard index < lines.count, lines[index].trimmed.hasPrefix(":"),
              let end = takeHeredoc(lines, from: index, directives: &directives, into: &block),
              directives.isEmpty, HeaderParser.isStructured(block) else { return nil }
        // The tag comment above the block is kept as a note rather than dropped.
        let notes = leading.filter { !$0.trimmed.isEmpty }.map { "** \($0.trimmed) **" }
        return (notes + [""] + block, end)
    }

    /// The start of the next comment paragraph after blank lines, when it still belongs to the header.
    /// Section banners and comments sitting directly on top of code belong to the code instead.
    private static func nextHeaderParagraph(_ lines: [String], after end: Int, language: ScriptLanguage) -> Int? {
        var start = end
        while start < lines.count, lines[start].trimmed.isEmpty { start += 1 }
        guard start > end else { return nil }
        var paragraph: [String] = []
        var cursor = start
        while cursor < lines.count, let text = lineComment(lines[cursor], language: language) {
            paragraph.append(text)
            cursor += 1
        }
        guard !paragraph.isEmpty else { return nil }
        let isBanner = paragraph.contains { $0.firstMatch(#"^[-=#*~_]{5,}\s*$"#) != nil } && !HeaderParser.isStructured(paragraph)
        if isBanner { return nil }
        let followedByCode = cursor < lines.count && !lines[cursor].trimmed.isEmpty
        if followedByCode, !HeaderParser.looksLikeHeader(paragraph) { return nil }
        return start
    }

    /// Reads a `: <<'HEADER'` heredoc header, with any directives and blank lines above it, and returns
    /// the index of the line after its closing delimiter. Returns nil when the lines aren't one.
    private static func takeHeredoc(_ lines: [String], from start: Int, directives: inout [String],
                                    into result: inout [String]) -> Int? {
        var index = start
        var found: [String] = []
        while index < lines.count, lines[index].trimmed.isEmpty || isDirective(lines[index], language: .bash) {
            if !lines[index].trimmed.isEmpty { found.append(lines[index]) }
            index += 1
        }
        guard index < lines.count,
              let delimiter = lines[index].trimmed.firstMatch(#"^:\s*<<-?\s*(['"]?)(\w+)\1\s*$"#)?[2] else { return nil }
        guard let end = lines[(index + 1)...].firstIndex(where: { $0.trimmed == delimiter }) else { return nil }
        directives += found
        result = Array(lines[(index + 1)..<end])
        return end + 1
    }

    /// Reads a block comment starting at `start` and returns the index of the line after it.
    private static func takeBlock(_ lines: [String], from start: Int, block: (open: String, close: String),
                                  language: ScriptLanguage, into result: inout [String]) -> Int {
        var first = lines[start].trimmed
        first.removeFirst(block.open.count)
        if language == .javaScript { first = String(first.drop { $0 == "*" }) }
        if let end = first.range(of: block.close) {
            result = [String(first[..<end.lowerBound]).trimmed].filter { !$0.isEmpty }
            return start + 1
        }
        var inner: [String] = first.trimmed.isEmpty ? [] : [first.trimmed]
        var index = start + 1
        while index < lines.count {
            var line = lines[index]
            if let end = line.range(of: block.close) {
                let before = String(line[..<end.lowerBound])
                if !before.trimmed.isEmpty, before.trimmed != "*" { inner.append(strip(before, language)) }
                result = inner
                return index + 1
            }
            line = strip(line, language)
            inner.append(line)
            index += 1
        }
        // An unterminated block isn't a header; leave the script alone.
        return start
    }

    /// Removes the ` * ` gutter JavaScript doc comments use.
    private static func strip(_ line: String, _ language: ScriptLanguage) -> String {
        guard language == .javaScript else { return line }
        return line.replacingOccurrences(of: #"^\s*\*\s?"#, with: "", options: .regularExpression)
    }

    /// The text of a line comment, or nil when the line isn't one.
    private static func lineComment(_ line: String, language: ScriptLanguage) -> String? {
        let trimmed = line.trimmed
        guard !trimmed.hasPrefix("#!") else { return nil }
        for prefix in language.lineCommentPrefixes where trimmed.hasPrefix(prefix) {
            var text = String(trimmed.dropFirst(prefix.count))
            if text.hasPrefix(" ") { text.removeFirst() }
            return text
        }
        return nil
    }

    /// Comment lines that change how the script runs or is linted, so must stay in place.
    private static func isDirective(_ line: String, language: ScriptLanguage) -> Bool {
        let lower = line.trimmed.lowercased()
        return lower.hasPrefix("# shellcheck") || lower.hasPrefix("#requires") || lower.hasPrefix("# requires -")
    }
}

/// The values read from an existing header or loose descriptive comment.
struct ParsedHeader {
    var fields: [HeaderParser.Field: String] = [:]
    var parameters: [HeaderRow] = []
    var sections: [HeaderRow] = []
    var exitCodes: [HeaderRow] = []
    var changeLog: [ChangeLogEntry] = []
    /// Free text that wasn't under a label; folded into the description.
    var looseText = ""
    /// Links to where the script came from, e.g. a blog post or GitHub repository.
    var sources: [String] = []
    /// True when the comment block had labelled fields rather than only prose.
    var isStructured = false
    /// Labelled lines with no matching field, e.g. `Fork:`.
    var extraFields: [HeaderRow] = []
    /// Free-standing `** … **` notes.
    var notes: [String] = []
    /// `* Heading` blocks with no matching field, kept line for line.
    var customSections: [HeaderBlock] = []

    var isEmpty: Bool { fields.isEmpty && looseText.isEmpty && changeLog.isEmpty }

    /// This header with the details of an older one folded in. The newer header wins, except where it only
    /// has a placeholder: an Unknown author, a later Created date or a lower version.
    func merged(with older: ParsedHeader) -> ParsedHeader {
        var result = self
        for (field, value) in older.fields where result.fields[field]?.trimmed.isEmpty ?? true {
            result.fields[field] = value
        }
        if let author = older.fields[.author], !author.trimmed.isEmpty,
           (fields[.author] ?? "").trimmed.caseInsensitiveCompare(HeaderDocument.unknownAuthor) == .orderedSame {
            result.fields[.author] = author
        }
        if let mine = fields[.created], let theirs = older.fields[.created],
           HeaderDate.normalise(theirs) < HeaderDate.normalise(mine) {
            result.fields[.created] = theirs
        }
        if let mine = version, let theirs = older.version, VersionBump.compare(theirs, mine) == .orderedDescending {
            result.fields[.version] = theirs
        }
        // The fuller description is kept; the other is usually a one-line summary of the same thing.
        if let theirs = older.fields[.description], theirs.count > (fields[.description] ?? "").count {
            result.fields[.description] = theirs
        }
        // Lists of files and requirements are combined, without repeating lines.
        for field in [HeaderParser.Field.output, .requirements] {
            let lines = (fields[field] ?? "").components(separatedBy: "\n") + (older.fields[field] ?? "").components(separatedBy: "\n")
            var unique: [String] = []
            for line in lines.map(\.trimmed) where !line.isEmpty && !unique.contains(line) { unique.append(line) }
            if !unique.isEmpty { result.fields[field] = unique.joined(separator: "\n") }
        }
        for row in older.extraFields where !result.extraFields.contains(where: { $0.key == row.key }) {
            result.extraFields.append(row)
        }
        result.notes += older.notes.filter { !result.notes.contains($0) }
        result.customSections += older.customSections.filter { block in !result.customSections.contains { $0.title == block.title } }
        result.parameters += older.parameters.filter { row in !result.parameters.contains { $0.key == row.key } }
        result.sections += older.sections.filter { row in !result.sections.contains { $0.key.lowercased() == row.key.lowercased() } }
        result.exitCodes += older.exitCodes.filter { row in !result.exitCodes.contains { $0.key == row.key } }
        // Older entries come first. One without an author was written by the older header's author.
        let olderAuthor = older.fields[.author]?.trimmed ?? ""
        let earlier = older.changeLog.map { entry in
            var entry = entry
            if entry.author.trimmed.isEmpty { entry.author = olderAuthor }
            return entry
        }.filter { entry in !changeLog.contains { $0.version == entry.version && $0.note == entry.note } }
        result.changeLog = earlier + changeLog
        result.sources += older.sources.filter { !result.sources.contains($0) }
        if result.looseText.isEmpty { result.looseText = older.looseText }
        result.isStructured = isStructured || older.isStructured
        return result
    }

    /// The header's version as MAJOR.MINOR.PATCH, if it has one.
    var version: String? {
        guard let text = fields[.version], let number = text.firstMatch(#"\d+(?:\.\d+){0,2}"#)?[0] else {
            return nil
        }
        var parts = number.split(separator: ".").map(String.init)
        while parts.count < 3 { parts.append("0") }
        return parts.joined(separator: ".")
    }

    var description: String {
        var text = fields[.description] ?? looseText
        for source in sources where !text.contains(source) {
            text += (text.isEmpty ? "" : "\n") + "Source: " + source
        }
        return text
    }
}

/// Reads labelled `Label : value` headers, including headers in other common styles.
enum HeaderParser {
    enum Field: String, CaseIterable {
        case scriptName, description, author, version, created, updated, output, deployment
        case parameters, sections, requirements, exitCodes, results, disclaimer, changeLog

        /// Labels recognised for this field, lowercased.
        var aliases: [String] {
            switch self {
            case .scriptName: ["script name", "name", "script", "file name", "filename"]
            case .description: ["description", "purpose", "summary", "synopsis", "about", ".synopsis", ".description"]
            case .author: ["author", "authors", "written by", "engineer", "created by"]
            case .version: ["version"]
            case .created: ["created", "date", "date created", "created on"]
            case .updated: ["updated", "last edit", "last edited", "last updated", "modified", "last modified", "date modified"]
            case .output: ["output", "outputs"]
            case .deployment: ["deployment", "deploy", "trigger"]
            case .parameters: ["parameters", "params", "jamf parameters"]
            case .sections: ["sections", "functions"]
            case .requirements: ["requirements", "requires", "dependencies", "prerequisites"]
            case .exitCodes: ["exit codes", "exit code", "return codes"]
            case .results: ["results", "possible results"]
            case .disclaimer: ["disclaimer"]
            case .changeLog: ["change log", "changelog", "history", "version history", "revision history", "changes"]
            }
        }

        /// Prose fields keep their line breaks; one-line fields are joined with spaces.
        var keepsLineBreaks: Bool { [.description, .output, .deployment, .requirements].contains(self) }

        static func matching(_ label: String) -> Field? {
            let key = label.lowercased().trimmed
            return allCases.first { $0.aliases.contains(key) }
        }
    }

    /// True when any line carries a known label.
    static func isStructured(_ lines: [String]) -> Bool {
        lines.contains { label(in: $0) != nil }
    }

    /// True when a comment paragraph carries header details: labels, a link, an author or a date.
    static func looksLikeHeader(_ lines: [String]) -> Bool {
        isStructured(lines) || lines.contains { line in
            let trimmed = line.trimmed
            return sourceURL(in: trimmed) != nil || looseAuthor(in: trimmed) != nil || looseDate(in: trimmed) != nil
                || trimmed.firstMatch(#"(?i)copyright|©"#) != nil
        }
    }

    /// A line that is only a link, e.g. `https://techitout.xyz/app-auto-patch`.
    private static func sourceURL(in line: String) -> String? {
        line.firstMatch(#"^(?:(?:source|from|see|based on|original)\s*:?\s*)?<?(https?://\S+?)>?$"#, options: [.caseInsensitive])?[1]
    }

    /// An attribution line such as `by Robert Schroeder` or `Written by Jane Smith`.
    private static func looseAuthor(in line: String) -> String? {
        guard let name = line.firstMatch(#"^(?:written |created |authored |developed |maintained )?by[:\s]+(.+?)\.?$"#,
                                         options: [.caseInsensitive])?[1] else { return nil }
        // Only a name or handle, so prose such as "by default, …" isn't taken as an author.
        return name.firstMatch(#"^(?:@[\w.-]+|\p{Lu}[\p{L}.'-]+(?:\s+(?:\p{Lu}[\p{L}.'-]+|de|van|von|der|la))*\s*(?:\(@?[\w.-]+\))?)$"#) != nil
            ? name : nil
    }

    /// A line that is only a date, e.g. `08.21.2025` or `2025-08-21`.
    private static func looseDate(in line: String) -> String? {
        line.firstMatch(#"^(?:date\s*:?\s*)?(\d{4}-\d{2}-\d{2}|\d{1,2}[./-]\d{1,2}[./-]\d{4})$"#, options: [.caseInsensitive])?[1]
    }

    /// Joins loose comment lines into prose, but keeps line breaks where the text is laid out, such as
    /// an example of the output or a list.
    private static func joinLoose(_ lines: [String]) -> String {
        var text = ""
        var previous: String?
        for line in lines {
            guard !line.isEmpty else {
                previous = nil  // paragraph break
                continue
            }
            if text.isEmpty {
                text = line
            } else if let previous {
                text += separator(after: previous, before: line) + line
            } else {
                text += "\n" + line
            }
            previous = line
        }
        return text
    }

    /// A space between lines of prose, or a line break where the text is laid out: after a line ending
    /// in a colon, and around output examples (`a | b`), tags and list items.
    private static func separator(after previous: String, before line: String) -> String {
        func isLaidOut(_ line: String) -> Bool {
            line.contains(" | ") || line.hasPrefix("<") || line.hasPrefix("- ") || line.hasPrefix("* ")
                || line.firstMatch(#"^\d+[.)]\s"#) != nil
        }
        let previous = previous.trimmed
        return previous.hasSuffix(":") || isLaidOut(previous) || isLaidOut(line) ? "\n" : " "
    }

    /// The script's header with any older headers under it merged in.
    static func parse(_ split: ScriptSplit) -> ParsedHeader {
        split.olderHeaders.reduce(parse(split.headerLines)) { $0.merged(with: parse($1)) }
    }

    static func parse(_ lines: [String]) -> ParsedHeader {
        var result = ParsedHeader()
        var current: Field?
        var loose: [String] = []
        var seenPowerShellNotes = false
        /// Column where rows start under Parameters, Sections or Exit Codes. Lines indented further
        /// carry on the row above; lines at the column are new rows.
        var rowColumn: Int?
        var lineIndent = 0
        /// True after a `* Heading` until its table's column titles have been skipped.
        var expectsTableHeader = false

        func append(_ text: String, to field: Field) {
            switch field {
            case .parameters, .sections, .exitCodes:
                if text.hasPrefix("|") {
                    appendTableRow(cells(text), to: field, in: &result)
                    return
                }
                // Rows listed under an empty label line take their column from the first row.
                if rowColumn == nil, !text.isEmpty, lineIndent > 0 { rowColumn = lineIndent }
                let continues = rowColumn.map { lineIndent > $0 }
                appendRow(text, to: field, continues: continues, in: &result)
            case .changeLog:
                appendChangeLog(text, in: &result)
            case .results:
                break  // always read again from the code
            default:
                guard !text.isEmpty else { return }
                if let existing = result.fields[field], !existing.isEmpty {
                    // Wrapped prose in a description is rejoined; laid-out lines keep their breaks.
                    let joiner = field == .description
                        ? separator(after: existing.components(separatedBy: "\n").last ?? "", before: text)
                        : field.keepsLineBreaks ? "\n" : " "
                    result.fields[field] = existing + joiner + text
                } else {
                    result.fields[field] = text
                }
            }
        }

        /// True while reading the lines of an unknown `* Heading` block, up to the next blank line.
        var inCustomSection = false
        /// Fields that hold one line, so a following `Other: value` line is its own field, not more text.
        let oneLineFields: Set<Field> = [.scriptName, .author, .version, .created, .updated]
        /// The extra field being read, so its indented continuation lines are added to it.
        var currentExtra: Int?

        for raw in lines {
            let line = raw.trimmed
            lineIndent = raw.prefix { $0 == " " }.count
            // Unknown `* Heading` blocks (e.g. `* Builds` with a table) are kept exactly, before any
            // ruler or table-row handling can drop their lines.
            if inCustomSection {
                if line.isEmpty {
                    inCustomSection = false
                } else {
                    result.customSections[result.customSections.count - 1].lines.append(raw)
                    continue
                }
            } else if let title = line.firstMatch(#"^\*\s+([^*\s].*?)\s*:?$"#)?[1], label(in: line) == nil {
                result.customSections.append(HeaderBlock(title: title, lines: []))
                inCustomSection = true
                current = nil
                continue
            }
            // `** Note **` lines outside a field are notes for whoever reads the header.
            if current == nil, line.firstMatch(#"^\*\*.+\*\*$"#) != nil {
                result.notes.append(line)
                continue
            }
            // Labels the house format has no field for, such as `Fork:`, `Components:` or `IMPORTANT:`, are
            // kept as their own fields. Under Author they would otherwise be read as more of the name.
            let startsExtra = label(in: line) == nil
                && (current.map { oneLineFields.contains($0) } ?? false || (result.isStructured && lineIndent == 0))
            if startsExtra, let parts = line.firstMatch(#"^([A-Z][A-Za-z]*(?: [A-Za-z]+){0,2})\s*:\s+(\S.*)$"#) {
                result.extraFields.append(HeaderRow(key: parts[1], value: parts[2]))
                currentExtra = result.extraFields.count - 1
                current = nil
                continue
            }
            if let extra = currentExtra {
                if line.isEmpty || lineIndent == 0 {
                    currentExtra = nil
                } else {
                    result.extraFields[extra].value += "\n" + line
                    continue
                }
            }
            if line.firstMatch(#"^[=\-#*_~]{3,}$"#) != nil { continue }  // ruler
            if line.firstMatch(#"^\|(?:\s*:?-+:?\s*\|)+$"#) != nil { continue }  // table alignment row
            if line.hasPrefix("|"), expectsTableHeader {
                expectsTableHeader = false  // column titles
                continue
            }
            if line.isEmpty {
                current = nil
                loose.append("")
                continue
            }
            if line.uppercased() == ".NOTES" || line.uppercased().hasPrefix(".PARAMETER") || line.uppercased() == ".EXAMPLE" {
                seenPowerShellNotes = true
                current = nil
                continue
            }
            // An indented line under a prose field carries on that field, even when a wrapped line happens
            // to start with a word that is also a label, such as "script: https://…".
            if let field = current, lineIndent >= 8, ![.parameters, .sections, .exitCodes, .changeLog].contains(field) {
                append(line, to: field)
                continue
            }
            if let (field, value) = label(in: line) {
                result.isStructured = true
                // PowerShell help keywords only fill the description when nothing better exists.
                if line.hasPrefix(".") {
                    current = result.fields[.description] == nil && !seenPowerShellNotes ? .description : nil
                    continue
                }
                if field == .description { result.fields[.description] = nil }
                current = field
                expectsTableHeader = line.hasPrefix("*")
                // On the label line itself the value always starts a row.
                rowColumn = value.isEmpty ? nil : raw.range(of: value).map { raw.distance(from: raw.startIndex, to: $0.lowerBound) }
                lineIndent = 0
                append(value, to: field)
                continue
            }
            if let current {
                append(line, to: current)
            } else if let source = sourceURL(in: line) {
                result.sources.append(source)
            } else if let name = looseAuthor(in: line), result.fields[.author] == nil {
                result.fields[.author] = name
            } else if let date = looseDate(in: line), result.fields[.created] == nil {
                result.fields[.created] = date
            } else {
                loose.append(line)
            }
        }
        result.looseText = joinLoose(loose)
        return result
    }

    /// The field and value when a line starts with a known label.
    private static func label(in line: String) -> (Field, String)? {
        let trimmed = line.trimmed
        if trimmed.hasPrefix("."), let field = Field.matching(trimmed) {
            return (field, "")
        }
        if let parts = trimmed.firstMatch(#"^([A-Za-z][A-Za-z ]{0,24}?)\s*:\s*(.*)$"#),
           let field = Field.matching(parts[1]) {
            return (field, parts[2].trimmed)
        }
        // `* Parameters` headings sit above a table.
        if let parts = trimmed.firstMatch(#"^\*\s+([A-Za-z][A-Za-z ]{0,24}?)\s*:?$"#), let field = Field.matching(parts[1]) {
            return (field, "")
        }
        // "Change Log" and "Changelog" often sit on their own line above the entries.
        if let field = Field.matching(trimmed), field == .changeLog {
            return (field, "")
        }
        return nil
    }

    /// Adds a row line. `continues` is true or false when indentation shows whether the line carries on
    /// the row above; nil means the indentation is unknown and the wording decides.
    private static func appendRow(_ text: String, to field: Field, continues: Bool?, in result: inout ParsedHeader) {
        guard !text.isEmpty else { return }
        var rows: [HeaderRow] = switch field {
        case .parameters: result.parameters
        case .sections: result.sections
        default: result.exitCodes
        }
        if continues == true, let last = rows.indices.last {
            rows[last].value += (rows[last].value.isEmpty ? "" : " ") + text
        } else if continues == false, text.firstMatch(#"^(\S+(?:\s\S+)*?)\s+[-–]\s+(.*)$"#) == nil {
            rows.append(HeaderRow(key: text, value: ""))
        } else if let parts = text.firstMatch(#"^(\S+(?:\s\S+)*?)\s+[-–]\s+(.*)$"#) {
            rows.append(HeaderRow(key: parts[1], value: parts[2]))
        } else if let parts = text.firstMatch(#"^(\S+)\s{2,}(.*)$"#) {
            rows.append(HeaderRow(key: parts[1], value: parts[2]))
        } else if let last = rows.indices.last,
                  field != .exitCodes || text.firstMatch(#"^\d+\b"#) == nil,
                  field != .sections || text.contains(" ") || rows[last].value.hasSuffix(",") || rows[last].value.hasSuffix(":") {
            // A single word under Sections is a section without a summary, unless it carries on a list.
            // A wrapped line carries on the previous row's meaning.
            rows[last].value += (rows[last].value.isEmpty ? "" : " ") + text
        } else {
            rows.append(HeaderRow(key: text, value: ""))
        }
        switch field {
        case .parameters: result.parameters = rows
        case .sections: result.sections = rows
        default: result.exitCodes = rows
        }
    }

    /// The cells of a Markdown table row; `\|` is a pipe inside a cell.
    private static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line.trimmed.dropFirst() {
            if escaped {
                current += character == "|" ? "|" : "\\" + String(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmed)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmed.isEmpty { cells.append(current.trimmed) }
        return cells
    }

    /// Adds a `| key | meaning |` row. A row with an empty key carries on the row above.
    private static func appendTableRow(_ cells: [String], to field: Field, in result: inout ParsedHeader) {
        guard let key = cells.first else { return }
        let value = cells.dropFirst().joined(separator: " ").trimmed
        var rows: [HeaderRow] = switch field {
        case .parameters: result.parameters
        case .sections: result.sections
        default: result.exitCodes
        }
        if key.isEmpty, let last = rows.indices.last {
            rows[last].value += (rows[last].value.isEmpty ? "" : " ") + value
        } else if !key.isEmpty {
            rows.append(HeaderRow(key: key, value: value))
        }
        switch field {
        case .parameters: result.parameters = rows
        case .sections: result.sections = rows
        default: result.exitCodes = rows
        }
    }

    private static func appendChangeLog(_ text: String, in result: inout ParsedHeader) {
        guard !text.isEmpty else { return }
        // | 1.0.0 | 2026-11-13 | Russell Collis | Initial release |, wrapped notes carry on in rows
        // with an empty version.
        if text.hasPrefix("|") {
            let cells = cells(text)
            guard let version = cells.first else { return }
            let note = cells.last ?? ""
            if version.isEmpty, cells.count > 1, let last = result.changeLog.indices.last {
                result.changeLog[last].note += " " + note
            } else if cells.count >= 3 {
                result.changeLog.append(ChangeLogEntry(version: version, date: HeaderDate.normalise(cells[1]),
                                                       author: cells.count >= 4 ? cells[2] : "", note: note))
            }
            return
        }
        // 1.0.0  2026-11-13  Russell Collis  Initial release
        if let parts = text.firstMatch(#"^v?(\d+(?:\.\d+)*)\s+(\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}/\d{4})\s+(.+?)\s{2,}(.*)$"#) {
            result.changeLog.append(ChangeLogEntry(version: parts[1], date: HeaderDate.normalise(parts[2]),
                                                   author: parts[3], note: parts[4]))
        // 09/11/2026 - v1.0 - Initial release
        } else if let parts = text.firstMatch(#"^(\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}/\d{4})\s*[-–]?\s*v(\d+(?:\.\d+)*)\s*[-–]\s*(.*)$"#)
            ?? text.firstMatch(#"^(\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}/\d{4})\s*[-–]\s*v?(\d+(?:\.\d+)*)\s*[-–]\s*(.*)$"#) {
            result.changeLog.append(ChangeLogEntry(version: parts[2], date: HeaderDate.normalise(parts[1]),
                                                   author: "", note: parts[3]))
        // 1.0 - 2026-11-13 - Initial release
        } else if let parts = text.firstMatch(#"^v?(\d+(?:\.\d+)*)\s*[-–]?\s*(\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}/\d{4})\s*[-–]?\s*(.*)$"#) {
            result.changeLog.append(ChangeLogEntry(version: parts[1], date: HeaderDate.normalise(parts[2]),
                                                   author: "", note: parts[3]))
        } else if let last = result.changeLog.indices.last {
            result.changeLog[last].note += " " + text
        }
    }
}
