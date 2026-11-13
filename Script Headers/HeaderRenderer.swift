import Foundation

/// Writes a `ScriptHeader` as a comment block in the house format, about 80 columns wide.
enum HeaderRenderer {
    static let lineWidth = 80
    /// Width of the label column, e.g. "Requirements" or "Script Name ".
    private static let labelWidth = 12

    /// The full script: preamble, new header, kept directives, then the code.
    static func apply(_ header: ScriptHeader, to split: ScriptSplit, language: ScriptLanguage) -> String {
        var lines = split.preamble
        lines += commentBlock(header, language: language)
        lines.append("")
        lines += split.directives
        var result = lines.joined(separator: "\n")
        if !split.body.isEmpty { result += "\n" + split.body }
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    /// The header with this language's comment markers.
    static func commentBlock(_ header: ScriptHeader, language: ScriptLanguage) -> [String] {
        switch language {
        case .bash, .zsh, .sh:
            return content(header, width: lineWidth - 2).map { $0.isEmpty ? "#" : "# " + $0 }
        case .python:
            return ["\"\"\""] + content(header, width: lineWidth - 2) + ["\"\"\""]
        case .appleScript:
            return ["(*"] + content(header, width: lineWidth - 2) + ["*)"]
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

    /// The header text without comment markers.
    static func content(_ header: ScriptHeader, width: Int) -> [String] {
        let ruler = String(repeating: "=", count: width)
        var lines = [ruler]
        lines += field("Script Name", header.scriptName, width: width)
        lines += field("Description", header.description, width: width)
        lines.append("")
        lines += field("Author", header.author, width: width)
        lines += field("Version", header.version, width: width)
        lines += field("Created", header.created, width: width)
        lines += field("Updated", header.updated, width: width)

        var deployment: [String] = []
        if !header.output.trimmed.isEmpty { deployment += field("Output", header.output, width: width) }
        deployment += field("Deployment", header.deployment, width: width)
        if !header.parameters.isEmpty { deployment += rows("Parameters", header.parameters, width: width) }
        lines.append("")
        lines += deployment

        if !header.sections.isEmpty {
            lines.append("")
            lines += rows("Sections", header.sections, width: width)
        }
        lines.append("")
        lines += field("Requirements", header.requirements, width: width)
        lines.append("")
        lines += rows("Exit Codes", header.exitCodes, width: width)
        lines.append("")
        if !header.disclaimer.trimmed.isEmpty {
            lines += field("Disclaimer", header.disclaimer, width: width)
            lines.append("")
        }
        lines += changeLog(header.changeLog, width: width)
        lines.append(ruler)
        return lines.map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
    }

    // MARK: - Pieces

    private static func prefix(_ label: String) -> String {
        label.padding(toLength: labelWidth, withPad: " ", startingAt: 0) + ": "
    }

    /// `Label       : value`, wrapped with continuation lines under the value column.
    private static func field(_ label: String, _ value: String, width: Int) -> [String] {
        let first = prefix(label)
        let indent = String(repeating: " ", count: first.count)
        return wrap(value, width: width - first.count).enumerated().map { ($0 == 0 ? first : indent) + $1 }
    }

    /// Aligned `key - meaning` rows under one label.
    private static func rows(_ label: String, _ rows: [HeaderRow], width: Int) -> [String] {
        let first = prefix(label)
        let indent = String(repeating: " ", count: first.count)
        // Only rows with a meaning need aligning, and the column is capped so one long name
        // doesn't squeeze every meaning into a narrow strip at the right.
        let maxKeyWidth = 22
        let keyWidth = rows.filter { !$0.value.trimmed.isEmpty }.map { $0.key.trimmed.count }
            .filter { $0 <= maxKeyWidth }.max() ?? 0
        let valueIndent = String(repeating: " ", count: keyWidth + 3)
        let valueWidth = width - first.count - valueIndent.count
        var lines: [String] = []
        for row in rows {
            let name = row.key.trimmed
            let value = row.value.trimmed
            guard !value.isEmpty else {
                lines.append(name)
                continue
            }
            let key = name.padding(toLength: max(keyWidth, name.count), withPad: " ", startingAt: 0) + " - "
            // A name longer than the column starts its meaning further right on the first line only.
            let firstWidth = width - first.count - key.count
            let firstLine = wrap(value, width: max(firstWidth, 20)).first ?? ""
            let rest = value.split(separator: " ", omittingEmptySubsequences: true)
                .dropFirst(firstLine.split(separator: " ").count)
                .joined(separator: " ")
            lines.append(key + firstLine)
            if !rest.isEmpty { lines += wrap(rest, width: valueWidth).map { valueIndent + $0 } }
        }
        return lines.enumerated().map { ($0 == 0 ? first : indent) + $1 }
    }

    /// `Change Log  :` followed by aligned version, date, author and note columns.
    private static func changeLog(_ entries: [ChangeLogEntry], width: Int) -> [String] {
        let versionWidth = entries.map(\.version.count).max() ?? 0
        let authorWidth = entries.map(\.author.count).max() ?? 0
        var lines = [prefix("Change Log").trimmed]
        for entry in entries {
            var start = "  " + entry.version.padding(toLength: versionWidth, withPad: " ", startingAt: 0)
                + "  " + entry.date
            if authorWidth > 0 { start += "  " + entry.author.padding(toLength: authorWidth, withPad: " ", startingAt: 0) }
            start += "  "
            let indent = String(repeating: " ", count: start.count)
            lines += wrap(entry.note, width: width - start.count).enumerated().map { ($0 == 0 ? start : indent) + $1 }
        }
        return lines
    }

    /// Word-wraps each line of `text` to `width`; existing line breaks are kept.
    static func wrap(_ text: String, width: Int) -> [String] {
        let width = max(width, 20)
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var current = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
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
        return lines.isEmpty ? [""] : lines
    }
}
