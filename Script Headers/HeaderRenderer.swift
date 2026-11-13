import Foundation

/// Writes a `ScriptHeader` in the house format: labelled `Name:` fields between dashed rulers, then
/// `* Parameters`, `* Sections`, `* Exit Codes` and `* Change Log` as Markdown tables. Shell scripts
/// wrap it in a `: <<'HEADER'` heredoc so the text needs no comment markers and the shell skips it.
enum HeaderRenderer {
    static let lineWidth = 80

    /// The heredoc delimiter that wraps shell headers: `: <<'HEADER'` … `HEADER`.
    static let heredocDelimiter = "HEADER"

    /// Width of the dashed rulers around the fields.
    private static let rulerWidth = 80

    /// The full script: preamble, new header, kept directives, then the code.
    static func apply(_ header: ScriptHeader, to split: ScriptSplit, language: ScriptLanguage) -> String {
        var lines = leadingLines(header, to: split, language: language)
        lines.append("")
        // Shell directives go above the header so they apply to the whole file.
        if !language.isShell { lines += split.directives }
        var result = lines.joined(separator: "\n")
        if !split.body.isEmpty { result += "\n" + split.body }
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    /// Everything from line 1 to the end of the header block.
    static func leadingLines(_ header: ScriptHeader, to split: ScriptSplit, language: ScriptLanguage) -> [String] {
        var lines = split.preamble
        if language.isShell, !split.directives.isEmpty {
            lines += split.directives
            lines.append("")
        }
        return lines + commentBlock(header, language: language)
    }

    /// The header wrapped for this language.
    static func commentBlock(_ header: ScriptHeader, language: ScriptLanguage) -> [String] {
        switch language {
        case .bash, .zsh, .sh:
            // A quoted delimiter stops the shell expanding `$4` or backticks inside the header.
            // A line that is exactly the delimiter would end the heredoc early, so it is indented.
            let body = content(header, width: lineWidth).map { $0 == heredocDelimiter ? " " + $0 : $0 }
            return [": <<'\(heredocDelimiter)'", ""] + body + ["", heredocDelimiter]
        case .python:
            return ["\"\"\""] + content(header, width: lineWidth) + ["\"\"\""]
        case .appleScript:
            return ["(*"] + content(header, width: lineWidth) + ["*)"]
        case .javaScript:
            return ["/**"] + content(header, width: lineWidth - 3).map { $0.isEmpty ? " *" : " * " + $0 } + [" */"]
        case .powerShell:
            // Intune reads comment-based help, so the summary goes in .SYNOPSIS and .DESCRIPTION.
            let indent = "    "
            let width = lineWidth - indent.count
            let synopsis = header.description.components(separatedBy: ". ").first ?? header.description
            var lines = ["<#", ".SYNOPSIS"]
            lines += wrap(synopsis, width: width).map { indent + $0 }
            lines.append(".DESCRIPTION")
            lines += wrap(header.description, width: width).map { indent + $0 }
            lines.append(".NOTES")
            lines += content(header, width: width).map { $0.isEmpty ? "" : indent + $0 }
            lines.append("#>")
            return lines
        }
    }

    /// The header text without comment markers: a ruled block of fields, then `* Heading` Markdown tables.
    ///
    ///     --------------------------------------------------------------------
    ///     Name:           install_chrome.sh
    ///     Description:    Installs Google Chrome.
    ///     --------------------------------------------------------------------
    ///
    ///     * Exit Codes
    ///     | Code | Meaning          |
    ///     | :--- | :---             |
    ///     | 1    | Download failed  |
    static func content(_ header: ScriptHeader, width: Int, includeOuterRulers: Bool = true) -> [String] {
        let ruler = String(repeating: "-", count: min(rulerWidth, width))
        var lines: [String] = []
        if includeOuterRulers { lines.append(ruler) }
        // Fields sit in spaced groups: name and description, author and version, then the dates.
        lines += field("Name", header.scriptName, width: width)
        lines += field("Description", header.description, width: width)
        lines.append("")
        lines += field("Author", header.author, width: width)
        lines += field("Version", header.version, width: width)
        lines.append("")
        lines += field("Created", header.created, width: width)
        lines += field("Last Edit", header.updated, width: width)
        for extra in header.extraFields {
            lines += field(extra.key, extra.value, width: width)
        }
        if !header.output.trimmed.isEmpty {
            lines.append("")
            lines += field("Output", header.output, width: width)
        }
        lines.append("")
        lines += field("Deployment", header.deployment, width: width)
        if !header.requirements.trimmed.isEmpty {
            lines.append("")
            lines += field("Requirements", header.requirements, width: width)
        }
        if includeOuterRulers { lines.append(ruler) }
        if !header.notes.isEmpty {
            lines.append("")
            lines += header.notes
        }

        /// A `* Title` heading with its table or text directly under it; a blank line would end the section.
        func section(_ title: String, _ block: [String]) {
            lines.append("")
            lines.append("* " + title)
            lines += block
        }
        // The script's own blocks, such as a list of builds, come first and are kept exactly as written.
        for block in header.customSections {
            section(block.title, block.lines)
        }
        if !header.parameters.isEmpty {
            section("Parameters", table(["Parameter", "Description"], header.parameters.map { [$0.key, $0.value] }, width: width))
        }
        if !header.sections.isEmpty {
            section("Sections", table(["Section", "Description"], header.sections.map { [$0.key, $0.value] }, width: width))
        }
        if !header.exitCodes.isEmpty {
            section("Exit Codes", table(["Code", "Meaning"], header.exitCodes.map { [$0.key, $0.value] }, width: width))
        }
        if !header.results.isEmpty {
            section("Results", table(["Result"], header.results.map { [$0] }, width: width))
        }
        if !header.disclaimer.trimmed.isEmpty {
            section("Disclaimer", wrap(header.disclaimer, width: width))
        }
        if !header.changeLog.isEmpty {
            let hasAuthor = header.changeLog.contains { !$0.author.trimmed.isEmpty }
            let columns = hasAuthor ? ["Version", "Date", "Author", "Change"] : ["Version", "Date", "Change"]
            let rows = header.changeLog.map { entry in
                hasAuthor ? [entry.version, entry.date, entry.author, entry.note] : [entry.version, entry.date, entry.note]
            }
            section("Change Log", table(columns, rows, width: width))
        }
        return lines.map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
    }

    // MARK: - Pieces

    /// Width of the label column including the colon, e.g. "Description:    ".
    private static let labelWidth = 16

    /// `Label:          value`, wrapped with continuation lines under the value column.
    private static func field(_ label: String, _ value: String, width: Int) -> [String] {
        guard !value.trimmed.isEmpty else { return [] }
        let prefix = (label + ":").padding(toLength: labelWidth, withPad: " ", startingAt: 0)
        let indent = String(repeating: " ", count: labelWidth)
        let available = max(20, width - labelWidth)
        let wrapped = wrap(value, width: available)
        return wrapped.enumerated().map { index, line in
            (index == 0 ? prefix : indent) + line
        }
    }

    /// An aligned Markdown table with a `| :--- |` row under the titles. A long last cell is wrapped onto
    /// extra rows with empty leading cells, which the parser joins back onto the row above.
    private static func table(_ columns: [String], _ rows: [[String]], width: Int) -> [String] {
        guard !rows.isEmpty else { return [] }
        let rows = rows.map { row in row.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") } }
        var lengths = columns.map { max($0.count, 4) }
        for row in rows {
            for (index, cell) in row.enumerated() where index < lengths.count - 1 {
                lengths[index] = max(lengths[index], cell.count)
            }
        }
        // "| " + cells joined by " | " + " |"
        let overhead = 4 + (columns.count - 1) * 3
        let others = lengths.dropLast().reduce(0, +)
        let longest = rows.map { $0.last?.count ?? 0 }.max() ?? 0
        lengths[lengths.count - 1] = max(lengths[lengths.count - 1], min(longest, max(15, width - overhead - others)))

        func line(_ cells: [String]) -> String {
            "| " + cells.enumerated().map { index, cell in
                cell.padding(toLength: max(lengths[index], cell.count), withPad: " ", startingAt: 0)
            }.joined(separator: " | ") + " |"
        }

        var lines = [line(columns), line(columns.map { _ in ":---" })]
        for row in rows {
            let leading = Array(row.dropLast())
            let last = wrap(row.last ?? "", width: lengths[lengths.count - 1])
            for (index, part) in (last.isEmpty ? [""] : last).enumerated() {
                let lead = index == 0 ? leading : leading.map { _ in "" }
                lines.append(line(lead + [part]))
            }
        }
        return lines
    }

    /// Wraps `text` to lines of at most `width` columns, preserving paragraph breaks.
    private static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            let trimmed = paragraph.trimmed
            guard !trimmed.isEmpty else { lines.append(""); continue }
            var current = ""
            for word in trimmed.split(separator: " ") {
                if current.isEmpty {
                    current = String(word)
                } else if current.count + 1 + word.count <= width {
                    current += " " + word
                } else {
                    lines.append(current)
                    current = String(word)
                }
            }
            if !current.isEmpty { lines.append(current) }
        }
        return lines
    }
}
