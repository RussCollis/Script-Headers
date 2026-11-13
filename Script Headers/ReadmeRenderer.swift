import Foundation

/// Writes a full Markdown README for a script, matching the Jamf Pro documentation house format.
enum ReadmeRenderer {
    /// Generates a full README from a `HeaderDocument`.
    static func markdown(for document: HeaderDocument) -> String {
        markdown(
            header: document.header,
            kind: document.kind,
            language: document.language,
            shebang: document.split.shebang,
            analysis: document.analysis,
            jamfURL: document.jamfWebURL,
            dataType: document.kind == .extensionAttribute ? document.dataType.rawValue : nil,
            minimumOS: document.minimumOS,
            insights: document.readmeInsights
        )
    }

    /// Backwards-compatible overload for standalone headers without a document.
    static func markdown(for header: ScriptHeader, kind: ScriptKind, language: ScriptLanguage) -> String {
        markdown(
            header: header,
            kind: kind,
            language: language,
            shebang: nil,
            analysis: ScriptAnalysis(),
            jamfURL: nil,
            dataType: nil,
            minimumOS: "",
            insights: nil
        )
    }

    /// Full Markdown README generation.
    static func markdown(
        header: ScriptHeader,
        kind: ScriptKind,
        language: ScriptLanguage,
        shebang: String?,
        analysis: ScriptAnalysis,
        jamfURL: URL?,
        dataType: String?,
        minimumOS: String,
        insights: ReadmeInsights? = nil
    ) -> String {
        var lines: [String] = []

        // 1. Title: # Name (vVersion)
        let titleName = displayTitle(from: header.scriptName)
        if !header.version.trimmed.isEmpty {
            let v = header.version.hasPrefix("v") || header.version.hasPrefix("V") ? header.version : "v\(header.version)"
            lines.append("# \(titleName) (\(v))")
        } else {
            lines.append("# \(titleName)")
        }
        lines.append("")

        // 2. ## Overview: Apple Intelligence's summary when written, otherwise the header description.
        lines.append("## Overview")
        lines.append("")
        if let overview = insights?.overview.trimmed, !overview.isEmpty {
            lines.append(overview)
            lines.append("")
        } else if !header.description.trimmed.isEmpty {
            lines.append(header.description.trimmed)
            lines.append("")
        }

        var overviewRows: [(String, String)] = []
        let scriptFileName = header.scriptName.isEmpty ? "script" : header.scriptName
        overviewRows.append(("Script", "`\(scriptFileName)`"))

        if let shebang = shebang?.trimmingCharacters(in: .whitespaces), !shebang.isEmpty {
            let cleanShebang = shebang.hasPrefix("#!") ? String(shebang.dropFirst(2)).trimmingCharacters(in: .whitespaces) : shebang
            overviewRows.append(("Shell", "`\(cleanShebang)`"))
        } else {
            overviewRows.append(("Shell", "`\(language.rawValue)`"))
        }

        let dateStr = extractDate(from: !header.updated.isEmpty ? header.updated : header.created)
        if !header.version.isEmpty {
            let verWithDate = dateStr.isEmpty ? header.version : "\(header.version) (\(dateStr))"
            overviewRows.append(("Version", verWithDate))
        }

        var runAs = "root (required by Jamf Pro)"
        if analysis.checksForRoot {
            if analysis.settings.contains(where: { $0.key == "DEBUG" }) {
                runAs = "root (required unless `DEBUG` is above 0)"
            } else {
                runAs = "root (checked by the script)"
            }
        } else if analysis.usesConsoleUser {
            runAs = "root (parts run as console user)"
        } else if kind == .extensionAttribute {
            runAs = "root (recon runs as root)"
        }
        overviewRows.append(("Run as", runAs))

        if analysis.labelCount > 0 {
            let countLabel = analysis.labelCount > 1000 ? "Over 1,100" : "\(analysis.labelCount)"
            overviewRows.append(("Labels", "\(countLabel) label entries in the case statement (approximate count)"))
        }

        if let dataType, !dataType.isEmpty {
            overviewRows.append(("Data Type", dataType))
        }

        if !minimumOS.isEmpty {
            overviewRows.append(("Minimum OS", minimumOS))
        }

        lines += table(["Item", "Detail"], overviewRows.map { [$0.0, $0.1] })

        // 3. ## Usage in Jamf: where the script lives in Jamf Pro, then its parameters.
        if jamfURL != nil || !header.parameters.isEmpty {
            lines.append("")
            lines.append("## Usage in Jamf")
        }
        if let jamfURL {
            lines.append("")
            lines.append("### URL")
            lines.append("")
            lines.append(jamfURL.absoluteString)
        }
        if !header.parameters.isEmpty {
            lines.append("")
            lines.append("### Parameters")
            lines.append("")
            var paramRows: [[String]] = []
            for (idx, row) in header.parameters.enumerated() {
                var key = row.key.replacingOccurrences(of: "$", with: "").trimmed
                if key == "5" && header.parameters.count == 2 && idx == 1 {
                    key = "5 onwards"
                }
                paramRows.append([key, row.value])
            }
            lines += table(["Parameter", "Description"], paramRows)
            lines.append("")
            if analysis.labelCount > 0 {
                lines.append("Jamf sends `/`, the computer name and the user name first; the script shifts these off automatically. Running with no label prints every available label, and the label `version` prints the version.")
            } else {
                lines.append("Jamf sends the target drive, the computer name and the user name as `$1` to `$3`; script parameters start at `$4`.")
            }
        }

        // 4. ## Settings in this copy
        if !analysis.settings.isEmpty {
            lines.append("")
            lines.append("## Settings in this copy")
            lines.append("")
            let settingRows = analysis.settings.map { row -> [String] in
                let pieces = row.value.components(separatedBy: "||||")
                let val = pieces.first ?? ""
                var meaning = pieces.count > 1 ? pieces[1] : ""
                // Settings the analyser couldn't explain take Apple Intelligence's meaning.
                if meaning.trimmed.isEmpty, let written = insights?.settingMeanings.first(where: { $0.name == row.key }) {
                    meaning = written.meaning
                }
                return ["`\(row.key)`", "`\(val)`", meaning]
            }
            lines += table(["Setting", "Value", "Meaning"], settingRows)
        }

        // 5. ## What it does: Apple Intelligence's steps, then the header's sections, then rules read from the code.
        lines.append("")
        lines.append("## What it does")
        lines.append("")
        if let steps = insights?.steps.filter({ !$0.title.trimmed.isEmpty }), !steps.isEmpty {
            // Each step reads like a line of the header's Sections list, with the explanation under it.
            for (idx, step) in steps.enumerated() {
                if idx > 0 { lines.append("") }
                lines += stepHeading(number: idx + 1, title: step.title, summary: step.summary)
                if !step.detail.trimmed.isEmpty {
                    lines.append("")
                    lines.append(step.detail.trimmed)
                }
                let points = step.keyPoints.map(\.trimmed).filter { !$0.isEmpty }
                if !points.isEmpty {
                    lines.append("")
                    lines += points.map { "- \($0)" }
                }
            }
        } else if !header.sections.isEmpty {
            for (idx, section) in header.sections.enumerated() {
                if idx > 0 { lines.append("") }
                // The section value can end with "Functions: a, b", which is listed on its own line.
                let pieces = section.value.components(separatedBy: "Functions: ")
                let summary = pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                lines += stepHeading(number: idx + 1, title: section.key, summary: summary)
                if pieces.count > 1 {
                    lines.append("")
                    lines.append("Functions: " + pieces[1].components(separatedBy: ", ").map { "`\($0.trimmed)`" }.joined(separator: ", "))
                }
            }
        } else {
            var steps: [String] = []
            if analysis.labelCount > 0 {
                // Installomator-style label scripts.
                steps.append("Reads the label and any overrides, optionally uses a proxy, and checks root.")
                if (analysis.requiredBinaries + analysis.optionalBinaries).contains(where: { $0.contains("dialog") }) {
                    steps.append("Uses swiftDialog for notifications when it is installed.")
                }
                steps.append("Looks up the label, finds the installed version, and compares it with the latest download.")
                steps.append("If an app is running, prompts or quits it according to `BLOCKING_PROCESS_ACTION`.")
                steps.append("Downloads, verifies the signature and Team ID, installs, and prints the installed location and version.")
            } else {
                if !header.parameters.isEmpty {
                    steps.append("Reads its settings from Jamf parameters \(header.parameters.map { "`\($0.key)`" }.joined(separator: ", ")).")
                }
                if analysis.checksForRoot { steps.append("Checks it is running as root.") }
                if analysis.usesConsoleUser { steps.append("Finds the logged-in user and runs parts of the work as that user.") }
                if !analysis.requiredBinaries.isEmpty {
                    steps.append("Does its work with \(analysis.requiredBinaries.map { "`\($0)`" }.joined(separator: ", ")).")
                }
                if !analysis.outputs.isEmpty {
                    steps.append("Writes \(analysis.outputs.joined(separator: ", ")).")
                }
                if kind == .extensionAttribute { steps.append("Prints the result between `<result>` tags for Jamf Pro inventory.") }
                if !header.exitCodes.isEmpty { steps.append("Exits with a code that shows whether it worked (see Exit Codes).") }
            }
            if steps.isEmpty {
                steps.append("Use Write README (Apple Intelligence) to describe how this script works.")
            }
            for (idx, step) in steps.enumerated() {
                lines.append("\(idx + 1). \(step)")
            }
        }

        // 6. ## Notes: rules read from the code, plus Apple Intelligence's cautions.
        var notes: [String] = []
        if analysis.settings.contains(where: { $0.key == "PROMPT_TIMEOUT" }) {
            notes.append("A user prompt can wait for up to 24 hours, which can hold up other Jamf management actions. For unattended policies consider overriding `PROMPT_TIMEOUT`, or `BLOCKING_PROCESS_ACTION=ignore` / `silent_fail`.")
        }
        if analysis.settings.contains(where: { $0.key == "INSTALL" && $0.value.contains("force") }) {
            notes.append("`INSTALL=force` differs from the upstream default (unset) and reinstalls every time.")
        }
        if analysis.usesEval {
            notes.append("Overrides are run through `eval`, so only trusted admin-set Jamf parameters should be used.")
        }
        if header.scriptName.localizedCaseInsensitiveContains("installomator") {
            notes.append("This is a community script with its own contributors list rather than the KPMG header; pull updates from the upstream project and review before replacing this copy.")
        }
        for note in insights?.notes.map(\.trimmed) ?? [] where !note.isEmpty && !notes.contains(note) {
            notes.append(note)
        }
        if !header.disclaimer.trimmed.isEmpty && !notes.contains(header.disclaimer.trimmed) {
            notes.append(header.disclaimer.trimmed)
        }
        if !notes.isEmpty {
            lines.append("")
            lines.append("## Notes")
            lines.append("")
            for note in notes {
                lines.append("- \(note)")
            }
        }

        // 7. ## Exit Codes (if any)
        if !header.exitCodes.isEmpty {
            lines.append("")
            lines.append("## Exit Codes")
            lines.append("")
            lines += table(["Code", "Meaning"], header.exitCodes.map { ["`\($0.key)`", $0.value] })
        }

        // 8. ## Change Log (if any)
        if !header.changeLog.isEmpty {
            lines.append("")
            lines.append("## Change Log")
            lines.append("")
            lines += table(["Version", "Date", "Author", "Change"], header.changeLog.map { [$0.version, $0.date, $0.author, $0.note] })
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// `### 1. Pre-flight Checks` with its short summary under it, like a line of the header's Sections list.
    private static func stepHeading(number: Int, title: String, summary: String) -> [String] {
        var lines = ["### \(number). \(title.trimmed)"]
        let summary = summary.trimmed
        if !summary.isEmpty, summary.lowercased() != title.trimmed.lowercased() {
            lines.append("")
            lines.append("*\(summary)*")
        }
        return lines
    }

    /// Derives a clean human-readable title from a script filename or name.
    static func displayTitle(from name: String) -> String {
        var title = (name as NSString).deletingPathExtension
        let prefixes = [#"^JSM[-_]+"#, #"^KPMG[-_]+"#, #"^corp[-_]+"#, #"^jamf[-_]+"#]
        for prefix in prefixes {
            title = title.replacingOccurrences(of: prefix, with: "", options: [.regularExpression, .caseInsensitive])
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        return title.isEmpty ? name : title
    }

    /// Extracts a YYYY-MM-DD date from a string.
    static func extractDate(from text: String) -> String {
        if let match = text.firstMatch(#"\b\d{4}-\d{2}-\d{2}\b"#) {
            return match[0]
        }
        return ""
    }

    /// A GitHub-flavored Markdown table with pipes and alignment dividers.
    private static func table(_ columns: [String], _ rows: [[String]]) -> [String] {
        func row(_ cells: [String]) -> String {
            "| " + cells.map {
                $0.trimmed.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
            }.joined(separator: " | ") + " |"
        }
        let dividers = columns.map { _ in "------" }
        return [row(columns), row(dividers)] + rows.map(row)
    }
}
