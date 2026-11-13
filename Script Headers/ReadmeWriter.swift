import Foundation
import FoundationModels

/// The prose parts of a README that Apple Intelligence writes from the script: how it works, in plain words.
/// Everything factual (shell, version, parameters, settings values) still comes from the code.
@Generable
struct ReadmeInsights: Equatable {
    @Guide(description: "One or two sentences for an IT admin saying what the script does and why. Bold the key term with **. No headings.")
    var overview: String

    @Guide(description: "What the script does when it runs, in order. If sections are listed, write exactly one step per section, in the same order, using each section's title. Otherwise write 3 to 7 steps.",
           .maximumCount(12))
    var steps: [ReadmeStep]

    @Guide(description: "Plain-English meaning of each listed setting that has no meaning yet. Leave empty if none are listed.")
    var settingMeanings: [SettingMeaning]

    @Guide(description: "Practical cautions for a Jamf admin deploying this script: risks, long waits, side effects, things to check. One sentence each. Leave empty if there is nothing useful to say.",
           .maximumCount(4))
    var notes: [String]
}

/// One stage of the script, written like a line in the header's Sections list with an explanation under it.
@Generable
struct ReadmeStep: Equatable {
    @Guide(description: "The section title exactly as listed, or a short title of 2 to 5 words, e.g. 'Pre-flight Checks'.")
    var title: String
    @Guide(description: "A short summary of 3 to 8 words in the style of a header Sections column, e.g. 'Make sure the uninstall tool exists'.")
    var summary: String
    @Guide(description: "Two to four sentences explaining what this part of the script does and why it is done this way. Put variable names, commands and file paths in backticks.")
    var detail: String
    @Guide(description: "Explanations of anything complex in this part: functions, one-liners, pipes, regex, awk/sed, exit codes or workarounds. Start each with the command or function in backticks, then say what it does and why, e.g. '`exec > >(tee -a \"$LOG_FILE\") 2>&1` sends all output to the log and to Jamf, so both keep a copy.' Leave empty if this part is simple.",
           .maximumCount(4))
    var keyPoints: [String]
}

/// What one variable in the script's settings block does.
@Generable
struct SettingMeaning: Equatable {
    @Guide(description: "The setting's variable name exactly as listed.")
    var name: String
    @Guide(description: "A few words saying what this value does, e.g. 'Notify the user on success'.")
    var meaning: String
}

/// Asks the on-device Apple Intelligence model to explain a script for its README.
enum ReadmeWriter {
    /// Why the model can't be used right now, in words for the user; nil when it's ready.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to write the README."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading. Try again shortly."
        case .unavailable:
            return "Apple Intelligence isn't available."
        }
    }

    /// The on-device model has a small context window, so the script itself is cut to this many characters.
    /// Facts the analyser has already read (settings, parameters, functions) are sent separately.
    private static let codeBudget = 4_500

    private static let instructions = """
        You write README documentation for macOS admin scripts deployed with Jamf Pro.
        Write in plain British English for IT administrators. Be specific to this script: \
        name the real commands, variables and files it uses. Never invent behaviour that isn't in the code. \
        Don't repeat the parameter or settings tables; explain how the script works and why. \
        Explain complex functions and one-liners so a future reader can follow them without reading the code.
        """

    /// Reads the script and returns the README prose. Throws if the model is unavailable or fails.
    static func insights(for document: HeaderDocument) async throws -> ReadmeInsights {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt(for: document), generating: ReadmeInsights.self)
        return response.content
    }

    /// Everything the model needs, with the code trimmed to fit.
    private static func prompt(for document: HeaderDocument) -> String {
        let header = document.header
        let analysis = document.analysis
        var parts: [String] = ["Script: \(header.scriptName)", "Language: \(document.language.rawValue)"]
        parts.append(document.kind == .extensionAttribute
                     ? "Type: Jamf Pro extension attribute (reports a <result> to inventory)"
                     : "Type: Jamf Pro policy script")
        if !header.description.trimmed.isEmpty { parts.append("Existing description: \(header.description.trimmed)") }
        if !header.parameters.isEmpty {
            parts.append("Jamf parameters:\n" + header.parameters.map { "- \($0.key): \($0.value)" }.joined(separator: "\n"))
        }
        if !analysis.settings.isEmpty {
            // Each setting is stored as "value||||meaning"; the model is only asked about blank meanings.
            parts.append("Settings:\n" + analysis.settings.map { row in
                let pieces = row.value.components(separatedBy: "||||")
                let meaning = pieces.count > 1 && !pieces[1].trimmed.isEmpty ? pieces[1] : "(no meaning yet)"
                return "- \(row.key)=\(pieces.first ?? "") : \(meaning)"
            }.joined(separator: "\n"))
        }
        if !header.sections.isEmpty {
            parts.append("Sections, in order (write one step for each):\n" + header.sections.enumerated().map { index, row in
                "\(index + 1). \(row.key)\(row.value.isEmpty ? "" : ": \(row.value)")"
            }.joined(separator: "\n"))
        }
        if !header.exitCodes.isEmpty {
            parts.append("Exit codes:\n" + header.exitCodes.map { "- \($0.key): \($0.value)" }.joined(separator: "\n"))
        }
        var facts: [String] = []
        if analysis.checksForRoot { facts.append("checks it is running as root") }
        if analysis.usesConsoleUser { facts.append("runs some commands as the logged-in user") }
        if analysis.usesEval { facts.append("uses eval on parameter values") }
        if analysis.labelCount > 0 { facts.append("has about \(analysis.labelCount) app labels in a case statement") }
        if !analysis.requiredBinaries.isEmpty { facts.append("uses " + analysis.requiredBinaries.joined(separator: ", ")) }
        if !analysis.optionalBinaries.isEmpty { facts.append("optionally uses " + analysis.optionalBinaries.joined(separator: ", ")) }
        if !analysis.outputs.isEmpty { facts.append("writes " + analysis.outputs.joined(separator: ", ")) }
        if !facts.isEmpty { parts.append("Known facts: the script " + facts.joined(separator: "; ") + ".") }
        parts.append("Code (comments removed, may be shortened):\n" + excerpt(of: document))
        return parts.joined(separator: "\n\n")
    }

    /// The code without comments or blank lines, cut to fit the model. When the script has section banners,
    /// each section gets an equal share, so the middle sections are explained as well as the first and last.
    private static func excerpt(of document: HeaderDocument) -> String {
        let body = document.split.body.components(separatedBy: "\n")
        let titles = document.header.sections.map(\.key)
        let starts = sectionStarts(of: titles, in: body, language: document.language)
        guard starts.count > 1 else {
            return shortened(code(body, document: document), to: codeBudget)
        }
        // Code before the first banner (often the shebang and settings) is kept with the first section.
        let share = codeBudget / starts.count
        return starts.enumerated().map { offset, start in
            let from = offset == 0 ? 0 : start.line
            let to = offset + 1 < starts.count ? starts[offset + 1].line : body.count
            return "## Section \(offset + 1): \(start.title)\n"
                + shortened(code(Array(body[from..<to]), document: document), to: share)
        }.joined(separator: "\n\n")
    }

    /// The line each section's banner is on, found by its title in a comment line, in script order.
    private static func sectionStarts(of titles: [String], in lines: [String],
                                      language: ScriptLanguage) -> [(line: Int, title: String)] {
        var starts: [(line: Int, title: String)] = []
        var searchFrom = 0
        for title in titles {
            let match = lines.indices.dropFirst(searchFrom).first { index in
                let trimmed = lines[index].trimmed
                return language.lineCommentPrefixes.contains { trimmed.hasPrefix($0) }
                    && trimmed.localizedCaseInsensitiveContains(title)
            }
            if let match {
                starts.append((match, title))
                searchFrom = match + 1
            }
        }
        return starts
    }

    /// Lines with comments and blanks removed. Long label case statements such as Installomator's are dropped,
    /// because the label count is already in the facts.
    private static func code(_ source: [String], document: HeaderDocument) -> String {
        let prefixes = document.language.lineCommentPrefixes
        var lines: [String] = []
        var caseDepth = 0
        for line in source {
            let trimmed = line.trimmed
            if trimmed.isEmpty || prefixes.contains(where: { trimmed.hasPrefix($0) }) { continue }
            if document.analysis.labelCount > 0 {
                if caseDepth > 0 {
                    // Nested case statements inside a label are counted so the right esac ends the skip.
                    if trimmed.hasPrefix("case ") { caseDepth += 1 }
                    if trimmed.hasPrefix("esac") {
                        caseDepth -= 1
                        if caseDepth == 0 { lines.append("    # … app labels omitted …"); lines.append(line) }
                    }
                    continue
                }
                if trimmed.hasPrefix("case ") && trimmed.contains("label") { caseDepth = 1; lines.append(line); continue }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Keeps the start and end of long code, where settings and the main logic usually are.
    private static func shortened(_ text: String, to budget: Int) -> String {
        guard text.count > budget else { return text }
        return text.prefix(budget * 3 / 5) + "\n# … omitted …\n" + text.suffix(budget * 2 / 5)
    }
}
