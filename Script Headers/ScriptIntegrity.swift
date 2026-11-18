import Foundation

// =============================================================================
// MARK: - Script integrity check
// =============================================================================

/// The last line of defence before anything is written: proves that the updated script still holds
/// every line of code the original had, in the same order, with nothing cut off, changed or added.
///
/// Why this exists: the header and the comments are built by rules, and a rule that misreads a script
/// (an odd heredoc, a block comment with code after it, a very long file) could otherwise drop or
/// split code without anyone noticing until the script fails on a Mac. So before Save, Save As,
/// Download, Copy or a Jamf Pro update, both versions are reduced to just their code and compared.
///
/// How: each script is scanned line by line. Blank lines, comments, the old/new header blocks and
/// `: <<'WORD'` no-op heredocs are left out, because those are the only things the app is allowed to
/// change. Everything else (including every line inside a real heredoc or multi-line string, where an
/// inserted comment would become data) is kept verbatim. The two lists must match exactly.
///
/// The check is independent of `ScriptSplit` on purpose: if the splitter itself has a bug, comparing
/// against its own `body` would agree with the bug. This scanner reads the raw text instead.
enum ScriptIntegrity {

    // -------------------------------------------------------------------------
    // MARK: Errors
    // -------------------------------------------------------------------------

    /// Why an update was refused. Shown in the "Couldn't Save" alert, so it is written for people.
    struct Failure: LocalizedError, Equatable {
        /// What went wrong, naming the first original line that didn't survive.
        let message: String

        var errorDescription: String? {
            message + "\n\nNothing was written. The original script is unchanged."
        }
    }

    /// One line of code and the line number (from 1) it sits on, so failures can point at it.
    private struct CodeLine: Equatable {
        let number: Int
        let text: String

        /// Only the text matters when comparing; the number moves when a header grows or shrinks.
        static func == (lhs: CodeLine, rhs: CodeLine) -> Bool { lhs.text == rhs.text }
    }

    // -------------------------------------------------------------------------
    // MARK: Public check
    // -------------------------------------------------------------------------

    /// Throws `Failure` unless `updated` keeps all of `original`'s code.
    ///
    /// - Parameters:
    ///   - original: The script as it was opened (from disk, the clipboard or Jamf Pro).
    ///   - updated: The script as it is about to be saved or pushed.
    ///   - language: Decides which comment and heredoc rules apply.
    ///   - addedLines: For "Comments only", the line indexes the commenter inserted. When given, the
    ///     check is stricter: removing just those lines must give back the original byte for byte,
    ///     header, comments, blank lines and all.
    static func verify(original: String, updated: String, language: ScriptLanguage,
                       addedLines: Set<Int>? = nil) throws {
        // Windows line endings are normalised on open, so compare both sides the same way.
        let originalLines = normalised(original)
        let updatedLines = normalised(updated)

        // 1. An empty result from a non-empty script is the worst kind of cut-off; say so plainly.
        let originalHasText = originalLines.contains { !$0.trimmed.isEmpty }
        if originalHasText, !updatedLines.contains(where: { !$0.trimmed.isEmpty }) {
            throw Failure(message: "The updated script came out empty.")
        }

        // 2. The shebang decides which interpreter runs the script, so it must still be line 1.
        if let shebang = originalLines.first, shebang.hasPrefix("#!"), updatedLines.first != shebang {
            throw Failure(message: "The first line (\(quoted(shebang))) is no longer the first line of the updated script.")
        }

        // 3. "Comments only" promises every original line is untouched, so hold it to exactly that.
        if let addedLines {
            let kept = updatedLines.enumerated().filter { !addedLines.contains($0.offset) }.map(\.element)
            try compare(numbered(originalLines), numbered(kept), what: ("line", "lines"))
        }

        // 4. Every mode: the code itself, with comments and headers set aside, must be identical.
        try compare(codeLines(originalLines, language: language),
                    codeLines(updatedLines, language: language), what: ("line of code", "lines of code"))

        // 5. Directives such as `# shellcheck disable=…` or `#Requires -Version 5` are comments, so step 4
        //    skips them, but they change how the script is linted or run, so none may go missing.
        let lostDirectives = directives(originalLines).filter { directive in
            !updatedLines.contains { $0.trimmed == directive.text.trimmed }
        }
        if let first = lostDirectives.first {
            throw Failure(message: "Line \(first.number) of the original (\(quoted(first.text))) is missing from the updated script.")
        }
    }

    // -------------------------------------------------------------------------
    // MARK: Comparison
    // -------------------------------------------------------------------------

    /// Throws a `Failure` describing the first place the two lists part ways.
    /// `what` names the lines in the message, singular and plural ("line of code" / "lines of code").
    private static func compare(_ original: [CodeLine], _ updated: [CodeLine], what: (one: String, many: String)) throws {
        guard original != updated else { return }
        // Walk both lists together to the first line that differs.
        let shared = zip(original, updated).prefix { $0 == $1 }.count
        if shared == updated.count {
            // The updated list ran out first: the end of the script was cut off.
            let missing = original.count - shared
            let first = original[shared]
            throw Failure(message: "The updated script is missing the last \(missing) \(missing == 1 ? what.one : what.many) "
                + "of the original, from line \(first.number) (\(quoted(first.text))).")
        }
        if shared == original.count {
            // The original ran out first: something was added that isn't a comment.
            let extra = updated[shared]
            throw Failure(message: "Line \(extra.number) of the updated script (\(quoted(extra.text))) "
                + "isn't in the original, so a \(what.one) would be added or changed.")
        }
        let lost = original[shared]
        throw Failure(message: "Line \(lost.number) of the original (\(quoted(lost.text))) "
            + "is missing or changed in the updated script.")
    }

    // -------------------------------------------------------------------------
    // MARK: Code scanner
    // -------------------------------------------------------------------------

    /// A heredoc opener: `<<WORD`, `<<-WORD`, `<<'WORD'` or `<<"WORD"`, anywhere on the line, so
    /// `cat <<EOF > file` counts too. `<<<` here-strings and `1<<2` shifts don't match.
    private static let heredocPattern = try? NSRegularExpression(pattern: #"(?<![<\w])<<(-?)\s*(['"]?)([A-Za-z_]\w*)\2"#)

    /// The lines of `lines` that are code, as the interpreter would see them.
    private static func codeLines(_ lines: [String], language: ScriptLanguage) -> [CodeLine] {
        var code: [CodeLine] = []

        // --- Scanner state: at most one of these is "open" at a time ---
        /// Inside a heredoc: the line that ends it, whether tabs before it are allowed (`<<-`), and
        /// whether it's a `: <<WORD` no-op used as a comment (its text is skipped, not kept).
        var heredoc: (delimiter: String, stripsTabs: Bool, isComment: Bool)?
        /// Inside a `/* … */`, `<# … #>` or `(* … *)` block comment.
        var inBlockComment = false
        /// Inside a Python triple-quoted string: its quote and whether it's a docstring (skipped).
        var pythonString: (quote: String, isDocstring: Bool)?
        /// The last code line ended in a backslash, so this line is still part of that command.
        var isContinued = false

        let block = language.blockComment

        for (index, line) in lines.enumerated() {
            let number = index + 1
            let trimmed = line.trimmed

            // Heredoc text is data: kept verbatim, comment-looking lines included, until the end word.
            if let open = heredoc {
                let candidate = open.stripsTabs ? String(line.drop { $0 == "\t" }) : line
                if candidate == open.delimiter { heredoc = nil }
                // The end word is kept with the data; a no-op comment heredoc keeps nothing.
                if !open.isComment { code.append(CodeLine(number: number, text: line)) }
                continue
            }

            // Python multi-line strings are data too; docstrings are documentation and are skipped.
            if let open = pythonString {
                if !open.isDocstring { code.append(CodeLine(number: number, text: line)) }
                if line.components(separatedBy: open.quote).count - 1 > 0 { pythonString = nil }
                continue
            }

            // Block comments are skipped, but code after the closing marker on the same line is kept.
            if inBlockComment, let block {
                if let close = trimmed.range(of: block.close) {
                    inBlockComment = false
                    let rest = String(trimmed[close.upperBound...]).trimmed
                    if !rest.isEmpty { code.append(CodeLine(number: number, text: rest)) }
                }
                continue
            }

            // A line continuing the previous command is code whatever it looks like.
            if isContinued {
                code.append(CodeLine(number: number, text: line))
                isContinued = trimmed.hasSuffix("\\")
                continue
            }

            if trimmed.isEmpty { continue }

            // A block comment starting the line (Python's `"""` is handled as a docstring below).
            if let block, language != .python, trimmed.hasPrefix(block.open) {
                let after = trimmed.dropFirst(block.open.count)
                if let close = after.range(of: block.close) {
                    let rest = String(after[close.upperBound...]).trimmed
                    if !rest.isEmpty { code.append(CodeLine(number: number, text: rest)) }
                } else {
                    inBlockComment = true
                }
                continue
            }

            // A Python docstring starting the line.
            if language == .python, let quote = ["\"\"\"", "'''"].first(where: { trimmed.hasPrefix($0) }) {
                if !trimmed.dropFirst(quote.count).contains(quote) { pythonString = (quote, true) }
                continue
            }

            // Line comments, the shebang and directives: the parts the app may rewrite.
            if language.lineCommentPrefixes.contains(where: { trimmed.hasPrefix($0) }) { continue }

            // Anything left is code.
            code.append(CodeLine(number: number, text: line))
            isContinued = trimmed.hasSuffix("\\")

            // Does this line open a heredoc? Only if its end word really appears later; otherwise
            // `echo "<<x"` would swallow the rest of the file and hide real problems.
            if language.isShell, let opener = heredocOpener(in: line),
               lines[(index + 1)...].contains(where: { (opener.stripsTabs ? String($0.drop { $0 == "\t" }) : $0) == opener.delimiter }) {
                let isComment = trimmed.firstMatch(#"^:\s*<<"#) != nil
                // The `: <<'HEADER'` line itself belongs to the header, which is allowed to change.
                if isComment { code.removeLast() }
                heredoc = (opener.delimiter, opener.stripsTabs, isComment)
            }

            // Does this line open a Python string that carries on (an odd number of triple quotes)?
            if language == .python {
                for quote in ["\"\"\"", "'''"] where (line.components(separatedBy: quote).count - 1) % 2 == 1 {
                    pythonString = (quote, false)
                    break
                }
            }

            // Does a block comment open part-way along the line and stay open?
            if let block, language != .python, let open = line.range(of: block.open, options: .backwards),
               line[open.upperBound...].range(of: block.close) == nil {
                inBlockComment = true
            }
        }
        return code
    }

    /// The end word of a heredoc opened on `line`, and whether it was `<<-` (leading tabs allowed).
    private static func heredocOpener(in line: String) -> (delimiter: String, stripsTabs: Bool)? {
        guard let regex = heredocPattern else { return nil }
        let text = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) else { return nil }
        return (text.substring(with: match.range(at: 3)), match.range(at: 1).length > 0)
    }

    // -------------------------------------------------------------------------
    // MARK: Helpers
    // -------------------------------------------------------------------------

    /// Comment lines that change how the script runs or is linted (same list `ScriptSplit` keeps).
    private static func directives(_ lines: [String]) -> [CodeLine] {
        numbered(lines).filter { line in
            let lower = line.text.trimmed.lowercased()
            return lower.hasPrefix("# shellcheck") || lower.hasPrefix("#requires") || lower.hasPrefix("# requires -")
        }
    }

    /// Lines with `\r\n` turned into `\n`, and the empty "line" after a final newline dropped so a
    /// file with and without a trailing newline compare the same.
    private static func normalised(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Every line with its line number, for the strict "Comments only" comparison.
    private static func numbered(_ lines: [String]) -> [CodeLine] {
        lines.enumerated().map { CodeLine(number: $0.offset + 1, text: $0.element) }
    }

    /// A line shown in a message: trimmed, and shortened so a very long line doesn't fill the alert.
    private static func quoted(_ line: String) -> String {
        let text = line.trimmed
        return "“" + (text.count > 80 ? String(text.prefix(77)) + "…" : text) + "”"
    }
}
