import Foundation

/// The kind of interaction a blocked prompt represents.
public enum PromptKind: String, Sendable, Equatable {
    /// A yes/no-style permission request ("Do you want to proceed?").
    case approval
    /// A multiple-choice question ("Which deployment target?").
    case question
    /// Unknown/unmatched shape — show the raw prompt + a raw send-keys box.
    /// NEVER carries a guessed keystroke.
    case freeText
}

/// How an option is chosen on this prompt's widget.
public enum AnswerStyle: Sendable, Equatable {
    /// Permission prompts ("1. Yes / 2. No") accept the number key directly.
    case numberedShortcut
    /// `AskUserQuestion` forms ("Tab/Arrow keys to navigate · Enter to select")
    /// ignore number keys — you move the `›` cursor with arrows, then Enter.
    case arrowNavigate
}

/// One selectable option in an approval/question prompt.
public struct PromptOption: Sendable, Equatable {
    public let label: String
    /// Raw keys to send for this option (e.g. `["1","enter"]`). Raw keys only.
    /// For `.arrowNavigate` forms this is derived from the cursor position, so
    /// prefer `ClassifiedPrompt.keysToAnswer(optionIndex:)` over this field.
    public let keysToSend: [String]
    /// Secondary description line shown under the label, if the prompt has one.
    public let description: String?
    /// Whether this option currently has the `›` cursor on it.
    public let isSelected: Bool
    /// Multi-select checkbox state (`[✓]` = checked). nil for single-select prompts.
    public let isChecked: Bool?
    /// A free-text option — selecting it lets you TYPE then submit (Claude's
    /// "Type something" / "Chat about this" options), rather than just toggle. The
    /// UI must offer a text field for these, not a plain button.
    public let isTextEntry: Bool

    public init(label: String, keysToSend: [String],
                description: String? = nil, isSelected: Bool = false,
                isChecked: Bool? = nil, isTextEntry: Bool = false) {
        self.label = label
        self.keysToSend = keysToSend
        self.description = description
        self.isSelected = isSelected
        self.isChecked = isChecked
        self.isTextEntry = isTextEntry
    }
}

/// One step in a multi-question wizard (Claude's `AskUserQuestion` tab bar,
/// e.g. `☒ Purpose  □ Topics  □ My role  ✓ Submit`).
public struct WizardStep: Sendable, Equatable {
    public let label: String
    /// `☒` — this question already has an answer.
    public let isAnswered: Bool
    /// The trailing `✓ Submit` step.
    public let isSubmit: Bool
    /// The step the user is currently on (best-effort from the on-screen markers).
    public let isCurrent: Bool

    public init(label: String, isAnswered: Bool, isSubmit: Bool, isCurrent: Bool) {
        self.label = label
        self.isAnswered = isAnswered
        self.isSubmit = isSubmit
        self.isCurrent = isCurrent
    }
}

/// A structured, renderable interaction produced from a pane's on-screen prompt.
public struct ClassifiedPrompt: Sendable, Equatable {
    public let kind: PromptKind
    public let options: [PromptOption]
    /// Keys that deny/cancel (usually `["esc"]`), when the shape offers it.
    public let denyKeys: [String]
    public let promptText: String
    public let isMarkdown: Bool
    /// The actual question being asked (Claude's forms put a question line above
    /// the options, e.g. "What is this study-coursera folder for?"). nil for a
    /// bare permission prompt.
    public let questionTitle: String?
    /// Multi-question wizard steps, if this is a multi-step form. Empty otherwise.
    public let steps: [WizardStep]
    /// How to choose an option: number key vs. arrow-navigate (see `AnswerStyle`).
    public let answerStyle: AnswerStyle
    /// Multi-select form (checkboxes) — answering toggles rather than commits.
    public let isMultiSelect: Bool

    public init(kind: PromptKind, options: [PromptOption], denyKeys: [String],
                promptText: String, isMarkdown: Bool,
                questionTitle: String? = nil, steps: [WizardStep] = [],
                answerStyle: AnswerStyle = .numberedShortcut, isMultiSelect: Bool = false) {
        self.kind = kind
        self.options = options
        self.denyKeys = denyKeys
        self.promptText = promptText
        self.isMarkdown = isMarkdown
        self.questionTitle = questionTitle
        self.steps = steps
        self.answerStyle = answerStyle
        self.isMultiSelect = isMultiSelect
    }

    /// True when this is a multi-question wizard (more than one step).
    public var isWizard: Bool { steps.count > 1 }

    /// Index of the currently-focused wizard step (from the ANSI highlight), or nil
    /// if we couldn't determine it.
    public var currentStepIndex: Int? {
        steps.firstIndex { $0.isCurrent }
    }

    /// Keystrokes to move from the current wizard step to `targetStepIndex` using
    /// the tab bar's ← → arrows. Returns [] if there's no wizard, we don't know the
    /// current step, or we're already there — the caller then does nothing rather
    /// than guess. (Verified mechanism: the bar shows `← … →` and the footer says
    /// "Tab/Arrow keys to navigate"; Left/Right move between question tabs.)
    public func keysToNavigate(toStepIndex target: Int) -> [String] {
        guard isWizard, steps.indices.contains(target), let current = currentStepIndex else { return [] }
        let delta = target - current
        guard delta != 0 else { return [] }
        return Array(repeating: delta > 0 ? "right" : "left", count: abs(delta))
    }

    /// The exact keystrokes to choose `optionIndex`, honoring the widget's answer
    /// style. For `.numberedShortcut` this is `[number, enter]`. For
    /// `.arrowNavigate` we move the `›` cursor from its current position to the
    /// target with `up`/`down`, then `enter` to select (single-select) or `space`
    /// to toggle (multi-select). Returns [] if we can't locate the cursor — the
    /// caller must then fall back to raw keys rather than guess.
    public func keysToAnswer(optionIndex: Int) -> [String] {
        guard options.indices.contains(optionIndex) else { return [] }
        switch answerStyle {
        case .numberedShortcut:
            return options[optionIndex].keysToSend
        case .arrowNavigate:
            guard let cursor = options.firstIndex(where: { $0.isSelected }) else { return [] }
            let delta = optionIndex - cursor
            let move = delta == 0 ? [] : Array(repeating: delta > 0 ? "down" : "up", count: abs(delta))
            return move + [isMultiSelect ? "space" : "enter"]
        }
    }

    /// The safe fallback: raw text, no guessed keys.
    public static func rawFallback(_ text: String) -> ClassifiedPrompt {
        ClassifiedPrompt(kind: .freeText, options: [], denyKeys: [],
                         promptText: text, isMarkdown: false)
    }
}

/// Compatibility facade around the exact-agent screen-adapter registry.
/// New parsing consumers should use `classifyInteraction`; the legacy
/// `ClassifiedPrompt` path remains until the M6 UI migration is complete.
public struct PromptClassifier: Sendable {
    public let registry: ScreenAdapterRegistry

    public init(registry: ScreenAdapterRegistry = .standard) {
        self.registry = registry
    }

    /// Temporary legacy view. Codex deliberately remains raw here until M3/M4
    /// connect normalized presentation to mandatory response revalidation.
    public func classify(agent: String?, text rawText: String, currentTabLabel: String? = nil) -> ClassifiedPrompt {
        registry.parse(ScreenAdapterInput(
            paneID: "legacy", agentID: agent, detectionText: rawText,
            currentTabLabel: currentTabLabel)).legacyPrompt
    }

    /// Pure normalized extraction through the exact-agent registry.
    public func classifyInteraction(paneID: String, agent: String?, text: String,
                                    visibleANSIText: String? = nil,
                                    paneRevision: UInt64? = nil,
                                    currentTabLabel: String? = nil) -> PendingInteraction {
        registry.parse(ScreenAdapterInput(
            paneID: paneID, agentID: agent, detectionText: text,
            visibleANSIText: visibleANSIText, paneRevision: paneRevision,
            currentTabLabel: currentTabLabel)).interaction
    }

    /// Parse Claude's multi-question tab bar, e.g.
    /// `← ☒ Purpose  □ Topics  □ My role  ✓ Submit →`.
    /// `☒`/`☑` = answered, `□` = pending, `✓ Submit` = the submit step. Returns []
    /// when there's no such bar (single-question or permission prompt).
    ///
    /// `currentLabel` (from a separate ANSI read) marks the focused tab. This
    /// function operates on CLEAN text (ANSI already stripped); it also strips ANSI
    /// defensively in case a caller passes an escaped line.
    ///
    /// Defensive: a real tab bar has a handful of tabs, each with a short label. If
    /// the candidate line yields an implausible token count or empty labels (which
    /// happened when a flaky full-screen read spliced in a wrong/wrapped line →
    /// "37 empty boxes"), we reject it and return [] rather than render garbage.
    public static func parseWizardSteps(_ text: String, currentLabel: String? = nil) -> [WizardStep] {
        // Candidate lines: contain a checkbox glyph AND "Submit".
        let candidates = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripAnsi(String($0)) }
            .filter { ($0.contains("☒") || $0.contains("□") || $0.contains("☑")) && $0.contains("Submit") }

        for line in candidates {
            let cleaned = line.replacingOccurrences(of: "←", with: "")
                .replacingOccurrences(of: "→", with: "")
                .replacingOccurrences(of: "\r", with: "")  // herdr visible read leaves CRs
            let tokens = cleaned.components(separatedBy: "  ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // A real tab bar has 2–8 tokens. More than that = we matched a wrong /
            // wrapped line; skip it.
            guard (2...8).contains(tokens.count) else { continue }

            var steps: [WizardStep] = []
            var ok = true
            for token in tokens {
                let isAnswered = token.hasPrefix("☒") || token.hasPrefix("☑")
                let isSubmit = token.contains("Submit")
                let label = token
                    .replacingOccurrences(of: "☒", with: "").replacingOccurrences(of: "☑", with: "")
                    .replacingOccurrences(of: "□", with: "").replacingOccurrences(of: "✓", with: "")
                    .replacingOccurrences(of: "✔", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Every token in a real bar has a non-empty label with a letter (a
                // lone glyph / stray CR is not a tab), reasonably short.
                guard label.contains(where: { $0.isLetter }), label.count <= 40 else { ok = false; break }
                let isCurrent = currentLabel != nil && label == currentLabel
                steps.append(WizardStep(label: label, isAnswered: isAnswered,
                                        isSubmit: isSubmit, isCurrent: isCurrent))
            }
            if ok && steps.count >= 2 { return steps }
        }
        return []
    }

    /// The visible label of the ANSI background-highlighted (`48;2;…m`) run on a
    /// line, box/check/cursor glyphs stripped. Scans ALL highlight runs and returns
    /// the first that resolves to a real tab label (contains a letter) — a line can
    /// carry more than one highlight run, and only the tab one has letters. nil if
    /// none qualifies.
    public static func highlightedTabLabel(in line: String) -> String? {
        var search = line.startIndex
        while let bgRange = line.range(of: "\u{1b}[48;2;", range: search..<line.endIndex) {
            guard let mAfterSGR = line[bgRange.upperBound...].firstIndex(of: "m") else { break }
            let start = line.index(after: mAfterSGR)
            let rest = line[start...]
            let end = rest.firstIndex(of: "\u{1b}") ?? rest.endIndex
            let visible = String(rest[..<end])
            let label = visible
                .replacingOccurrences(of: "☒", with: "").replacingOccurrences(of: "☑", with: "")
                .replacingOccurrences(of: "□", with: "").replacingOccurrences(of: "✔", with: "")
                .replacingOccurrences(of: "✓", with: "")
                .replacingOccurrences(of: "›", with: "").replacingOccurrences(of: "»", with: "")
                .trimmingCharacters(in: .whitespaces)
            if label.contains(where: { $0.isLetter }) { return label }
            search = end    // this run wasn't a tab label (e.g. a lone ›); try the next
        }
        return nil
    }

    /// Remove ANSI SGR escape sequences (`\u{1b}[…m`) from a string.
    static func stripAnsi(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\u{1b}", let m = s[i...].firstIndex(of: "m") {
                i = s.index(after: m)   // skip the whole escape
            } else {
                out.append(s[i]); i = s.index(after: i)
            }
        }
        return out
    }

    /// The question line: Claude renders it just above the numbered options,
    /// typically ending in `?`. We take the last non-empty, non-structural line
    /// before the first option that reads like a prompt.
    static func parseQuestionTitle(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Find the first option line (starts with optional › then "N.").
        guard let firstOptIdx = lines.firstIndex(where: { isOptionLine($0) }) else { return nil }
        // Walk backwards from there for the nearest meaningful line.
        for i in stride(from: firstOptIdx - 1, through: 0, by: -1) {
            let s = lines[i].trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            // Skip separator rules and the wizard tab bar.
            if s.allSatisfy({ $0 == "─" || $0 == "—" || $0 == "-" }) { continue }
            if s.contains("Submit") && (s.contains("□") || s.contains("☒") || s.contains("☑")) { continue }
            return s
        }
        return nil
    }

    private static func isOptionLine(_ line: String) -> Bool {
        var s = line.trimmingCharacters(in: .whitespaces)
        for marker in ["❯", "›", ">"] where s.hasPrefix(marker) {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard let dot = s.firstIndex(of: "."), let d = s.first, d.isNumber,
              s.distance(from: s.startIndex, to: dot) == 1 else { return false }
        return true
    }

    /// Parse a numbered menu: lines like `1. Yes`, `› 2. No … (esc)`, capturing
    /// the current-selection marker (`›` / trailing `✓`) and a following indented
    /// description line (Claude's forms put a description under each option).
    static func parseNumberedOptions(_ text: String) -> [PromptOption] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var options: [PromptOption] = []
        var i = 0
        while i < lines.count {
            guard let parsed = parseOptionLine(lines[i]) else { i += 1; continue }
            // Look ahead for an indented description line that is NOT itself an option
            // and not a separator/hint.
            var description: String?
            if i + 1 < lines.count {
                let next = lines[i + 1]
                let trimmed = next.trimmingCharacters(in: .whitespaces)
                let nextIsOption = parseOptionLine(next) != nil
                let looksIndentedDesc = next.hasPrefix("  ") || next.hasPrefix("\t")
                let isSeparatorOrHint = trimmed.isEmpty
                    || trimmed.allSatisfy { $0 == "─" || $0 == "—" || $0 == "-" }
                    || trimmed.lowercased().contains("to select")
                    || trimmed.lowercased().contains("to navigate")
                if !nextIsOption && looksIndentedDesc && !isSeparatorOrHint {
                    description = trimmed
                }
            }
            // A free-text option: Claude's "Type something" / "Chat about this",
            // or an option whose follow-up line is just "Submit" (the text-field
            // affordance). Selecting these expects typed input, not a toggle.
            let lower = parsed.label.lowercased()
            let isTextEntry = lower.contains("type something")
                || lower.contains("chat about")
                || (description?.caseInsensitiveCompare("Submit") == .orderedSame)
            options.append(PromptOption(label: parsed.label, keysToSend: [parsed.number, "enter"],
                                        description: description, isSelected: parsed.selected,
                                        isChecked: parsed.checked, isTextEntry: isTextEntry))
            i += 1
        }
        return options
    }

    private struct ParsedOption { let number: String; let label: String; let selected: Bool; let checked: Bool? }

    /// Parse a single option line. Returns nil if the line isn't a numbered option.
    /// Handles both shapes:
    ///   `› 2. No, and tell Claude…`            (single-select, › or trailing ✓ = cursor)
    ///   `› 1. [✓] Organize & take notes`       (multi-select, `[✓]`/`[ ]` = checkbox)
    private static func parseOptionLine(_ line: String) -> ParsedOption? {
        var s = line.trimmingCharacters(in: .whitespaces)
        var selected = false
        for marker in ["❯", "›", ">"] where s.hasPrefix(marker) {
            selected = true
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // Expect: <digit>. <label>
        guard let dot = s.firstIndex(of: "."),
              let digit = s.first, digit.isNumber,
              s.distance(from: s.startIndex, to: dot) == 1
        else { return nil }

        let number = String(digit)
        var label = String(s[s.index(after: dot)...]).trimmingCharacters(in: .whitespaces)

        // Leading checkbox `[✓]` / `[ ]` (multi-select). Detect + strip.
        var checked: Bool?
        if label.hasPrefix("["), let close = label.firstIndex(of: "]") {
            let inside = label[label.index(after: label.startIndex)..<close].trimmingCharacters(in: .whitespaces)
            checked = inside.contains("✓") || inside.contains("✔") || inside.lowercased() == "x"
            label = String(label[label.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }

        // A trailing ✓/✔ marks the currently-cursored option in single-select forms.
        for check in ["✔", "✓"] where label.hasSuffix(check) {
            selected = true
            label = String(label.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        // Strip a trailing "(esc)" hint.
        if let range = label.range(of: "(esc)", options: [.caseInsensitive, .backwards]) {
            label = label[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        guard !label.isEmpty else { return nil }
        return ParsedOption(number: number, label: label, selected: selected, checked: checked)
    }

    /// Heuristic: plan-review prompts render Markdown (headings, bullets, code fences).
    static func looksLikeMarkdown(_ text: String) -> Bool {
        let markers = ["```", "\n# ", "\n## ", "\n- ", "\n* ", "\n1. "]
        return markers.contains { text.contains($0) }
    }
}
