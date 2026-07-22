import Foundation

/// Screen-only parser output used internally by the Claude adapter. UI and
/// response consumers receive `PendingInteraction`, never this transport shape.
struct ParsedTerminalOption: Sendable, Equatable {
    let label: String
    let description: String?
    let isSelected: Bool
    let isChecked: Bool?
    let isTextEntry: Bool
}

struct ParsedTerminalStep: Sendable, Equatable {
    let label: String
    let isAnswered: Bool
    let isSubmit: Bool
    let isCurrent: Bool
}

/// Normalized facade around exact-agent screen adapters plus shared terminal
/// parsing utilities. All public classification returns `PendingInteraction`.
public struct PromptClassifier: Sendable {
    public let registry: ScreenAdapterRegistry

    public init(registry: ScreenAdapterRegistry = .standard) {
        self.registry = registry
    }

    public func classifyInteraction(
        paneID: String, agent: String?, text: String,
        visibleANSIText: String? = nil, paneRevision: UInt64? = nil,
        currentTabLabel: String? = nil
    ) -> PendingInteraction {
        registry.parse(ScreenAdapterInput(
            paneID: paneID, agentID: agent, detectionText: text,
            visibleANSIText: visibleANSIText, paneRevision: paneRevision,
            currentTabLabel: currentTabLabel))
    }

    static func parseWizardSteps(
        _ text: String, currentLabel: String? = nil
    ) -> [ParsedTerminalStep] {
        let candidates = text.split(
            separator: "\n", omittingEmptySubsequences: false)
            .map { stripAnsi(String($0)) }
            .filter {
                ($0.contains("☒") || $0.contains("□") || $0.contains("☑"))
                    && $0.contains("Submit")
            }

        for line in candidates {
            let cleaned = line.replacingOccurrences(of: "←", with: "")
                .replacingOccurrences(of: "→", with: "")
                .replacingOccurrences(of: "\r", with: "")
            let tokens = cleaned.components(separatedBy: "  ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard (2...8).contains(tokens.count) else { continue }

            var steps: [ParsedTerminalStep] = []
            var valid = true
            for token in tokens {
                let isAnswered = token.hasPrefix("☒") || token.hasPrefix("☑")
                let isSubmit = token.contains("Submit")
                let label = token
                    .replacingOccurrences(of: "☒", with: "")
                    .replacingOccurrences(of: "☑", with: "")
                    .replacingOccurrences(of: "□", with: "")
                    .replacingOccurrences(of: "✓", with: "")
                    .replacingOccurrences(of: "✔", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard label.contains(where: { $0.isLetter }),
                      label.count <= 40 else {
                    valid = false
                    break
                }
                steps.append(ParsedTerminalStep(
                    label: label, isAnswered: isAnswered,
                    isSubmit: isSubmit,
                    isCurrent: currentLabel != nil && label == currentLabel))
            }
            if valid, steps.count >= 2 { return steps }
        }
        return []
    }

    public static func highlightedTabLabel(in line: String) -> String? {
        var search = line.startIndex
        while let background = line.range(
            of: "\u{1b}[48;2;", range: search..<line.endIndex) {
            guard let markerEnd = line[background.upperBound...].firstIndex(of: "m")
            else { break }
            let start = line.index(after: markerEnd)
            let remainder = line[start...]
            let end = remainder.firstIndex(of: "\u{1b}") ?? remainder.endIndex
            let label = String(remainder[..<end])
                .replacingOccurrences(of: "☒", with: "")
                .replacingOccurrences(of: "☑", with: "")
                .replacingOccurrences(of: "□", with: "")
                .replacingOccurrences(of: "✔", with: "")
                .replacingOccurrences(of: "✓", with: "")
                .replacingOccurrences(of: "›", with: "")
                .replacingOccurrences(of: "»", with: "")
                .trimmingCharacters(in: .whitespaces)
            if label.contains(where: { $0.isLetter }) { return label }
            search = end
        }
        return nil
    }

    public static func stripAnsi(_ value: String) -> String {
        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "\u{1b}",
               let markerEnd = value[index...].firstIndex(of: "m") {
                index = value.index(after: markerEnd)
            } else {
                output.append(value[index])
                index = value.index(after: index)
            }
        }
        return output
    }

    /// Bounds Claude parsing to the newest choice block instead of treating the
    /// whole detection screen (which can include scrollback) as prompt content.
    static func latestInteractionRegion(_ text: String) -> String? {
        let lines = text.split(
            separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstOption = lines.lastIndex(where: {
            parseOptionLine($0)?.number == 1
        }), let titleIndex = questionTitleIndex(in: lines, before: firstOption) else {
            return nil
        }

        var startIndex = titleIndex
        let titleIsApproval = lines[titleIndex].lowercased().contains("do you want to")
        if !titleIsApproval, let wizardIndex = lines.indices.last(where: {
            $0 < titleIndex && isWizardLine(lines[$0])
        }) {
            startIndex = wizardIndex
        } else if let ruleIndex = lines.indices.last(where: {
            $0 < titleIndex && isPromptRule(lines[$0])
        }) {
            if trimmedRule(lines[ruleIndex]).allSatisfy({ $0 == "╌" }),
               let openingRule = lines.indices.last(where: {
                   $0 < ruleIndex && trimmedRule(lines[$0]).count >= 8
                       && trimmedRule(lines[$0]).allSatisfy { $0 == "╌" }
               }) {
                startIndex = max(lines.startIndex, openingRule - 2)
            } else {
                let hasCardBody = lines[(ruleIndex + 1)..<titleIndex].contains {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                startIndex = hasCardBody
                    ? max(lines.startIndex, ruleIndex - 1) : titleIndex
            }
        }
        return lines[startIndex...].joined(separator: "\n")
    }

    static func parseQuestionTitle(_ text: String) -> String? {
        let lines = text.split(
            separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstOption = lines.firstIndex(where: isOptionLine) else {
            return nil
        }
        return questionTitleIndex(in: lines, before: firstOption).map { lines[$0]
            .trimmingCharacters(in: .whitespaces) }
    }

    private static func questionTitleIndex(in lines: [String], before firstOption: Int)
        -> Int? {
        guard firstOption > 0 else { return nil }
        for index in stride(from: firstOption - 1, through: 0, by: -1) {
            let value = lines[index].trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            if value.allSatisfy({ $0 == "─" || $0 == "—" || $0 == "-" }) {
                continue
            }
            if value.contains("Submit"),
               value.contains("□") || value.contains("☒") || value.contains("☑") {
                continue
            }
            return index
        }
        return nil
    }

    private static func isWizardLine(_ line: String) -> Bool {
        line.contains("Submit")
            && (line.contains("□") || line.contains("☒") || line.contains("☑"))
    }

    private static func isPromptRule(_ line: String) -> Bool {
        let value = trimmedRule(line)
        return value.count >= 8
            && value.allSatisfy { $0 == "─" || $0 == "╌" || $0 == "—" }
    }

    private static func trimmedRule(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseNumberedOptions(_ text: String) -> [ParsedTerminalOption] {
        let rawLines = text.split(
            separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let columnLayout = splitChoiceAndPreviewColumns(rawLines)
        let lines = columnLayout.choiceLines
        var options: [ParsedTerminalOption] = []
        var index = 0
        while index < lines.count {
            guard let parsed = parseOptionLine(lines[index]) else {
                index += 1
                continue
            }
            let descriptionLines = optionDescriptionLines(
                in: lines, after: index)
            let description = descriptionLines.isEmpty
                ? nil : descriptionLines.joined(separator: "\n")
            let lower = parsed.label.lowercased()
            options.append(ParsedTerminalOption(
                label: parsed.label, description: description,
                isSelected: parsed.selected, isChecked: parsed.checked,
                isTextEntry: lower.contains("type something")
                    || lower.contains("chat about")
                    || description?.caseInsensitiveCompare("Submit") == .orderedSame))
            index += 1
        }
        return options
    }

    static func selectedChoicePreview(_ text: String) -> String? {
        let lines = text.split(
            separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return splitChoiceAndPreviewColumns(lines).selectedPreview?
            .joined(separator: "\n")
    }

    private struct NumberedOptionColumnLayout {
        let choiceLines: [String]
        let selectedPreview: [String]?
    }

    /// Claude's richer question UI can place numbered choices beside a box
    /// preview. The detection read is a terminal grid, so without separating
    /// columns the right-hand card becomes part of each option label.
    private static func splitChoiceAndPreviewColumns(
        _ lines: [String]
    ) -> NumberedOptionColumnLayout {
        let topCorners: Set<Character> = ["┌", "╭", "┏"]
        guard let column = lines.lazy.compactMap({ line -> Int? in
            guard parseOptionLine(line) != nil,
                  let corner = line.firstIndex(where: topCorners.contains) else {
                return nil
            }
            let offset = line.distance(from: line.startIndex, to: corner)
            return offset >= 12 ? offset : nil
        }).first else {
            return NumberedOptionColumnLayout(
                choiceLines: lines, selectedPreview: nil)
        }

        let choiceLines = lines.map { prefix($0, characterCount: column) }
        let previewLines = cleanBoxPreview(lines.map {
            suffix($0, droppingCharacters: column)
        })
        return NumberedOptionColumnLayout(
            choiceLines: choiceLines,
            selectedPreview: previewLines.isEmpty ? nil : previewLines)
    }

    private static func cleanBoxPreview(_ lines: [String]) -> [String] {
        let topCorners: Set<Character> = ["┌", "╭", "┏"]
        let bottomCorners: Set<Character> = ["└", "╰", "┗"]
        let verticalEdges: Set<Character> = ["│", "┃"]
        var isInsideBox = false
        var content: [String] = []

        for line in lines {
            var value = line.trimmingCharacters(in: .whitespaces)
            guard let first = value.first else { continue }
            if topCorners.contains(first) {
                isInsideBox = true
                continue
            }
            guard isInsideBox else { continue }
            if bottomCorners.contains(first) { break }
            guard verticalEdges.contains(first) else { continue }

            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespaces)
            if let last = value.last, verticalEdges.contains(last) {
                value.removeLast()
                value = value.trimmingCharacters(in: .whitespaces)
            }
            if !value.isEmpty { content.append(value) }
        }
        return content
    }

    private static func prefix(_ value: String, characterCount: Int) -> String {
        let end = value.index(
            value.startIndex, offsetBy: characterCount,
            limitedBy: value.endIndex) ?? value.endIndex
        return String(value[..<end])
    }

    private static func suffix(_ value: String, droppingCharacters count: Int) -> String {
        guard let start = value.index(
            value.startIndex, offsetBy: count,
            limitedBy: value.endIndex) else { return "" }
        return String(value[start...])
    }

    /// Claude can render a choice as a small document: wrapped prose, an ASCII
    /// table, and notes can all belong to the same numbered option. Keep that
    /// block intact until the next numbered choice instead of retaining only
    /// its first visual line.
    private static func optionDescriptionLines(
        in lines: [String], after optionIndex: Int
    ) -> [String] {
        guard optionIndex + 1 < lines.count else { return [] }
        var result: [String] = []
        var index = optionIndex + 1
        while index < lines.count {
            let line = lines[index]
            if parseOptionLine(line) != nil { break }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isInteractionFooter(trimmed) { break }

            let isIndented = line.hasPrefix("  ") || line.hasPrefix("\t")
            guard trimmed.isEmpty || isIndented else { break }
            result.append(trimmed)
            index += 1
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    private static func isInteractionFooter(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("enter to select")
            || lower.contains("to navigate")
            || lower.contains("esc to cancel")
            || lower.contains("esc to interrupt")
    }

    static func interactionBody(_ text: String, excluding title: String?) -> String? {
        let lines = stripAnsi(text).split(
            separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let stable = lines.compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != title else { return nil }
            if value.allSatisfy({ $0 == "─" || $0 == "—" || $0 == "-" }) {
                return nil
            }
            if isOptionLine(value) { return nil }
            let lower = value.lowercased()
            if lower.contains("enter to select")
                || lower.contains("arrow keys to navigate")
                || lower.contains("tab/arrow keys to navigate")
                || lower.contains("esc to cancel")
                || lower.contains("tab to amend") {
                return nil
            }
            if value.contains("Submit"),
               value.contains("□") || value.contains("☒") || value.contains("☑") {
                return nil
            }
            return value
        }
        return stable.isEmpty ? nil : stable.joined(separator: "\n")
    }

    static func looksLikeMarkdown(_ text: String) -> Bool {
        ["```", "\n# ", "\n## ", "\n- ", "\n* ", "\n1. "]
            .contains { text.contains($0) }
    }

    private struct ParsedOption {
        let number: Int
        let label: String
        let selected: Bool
        let checked: Bool?
    }

    private static func isOptionLine(_ line: String) -> Bool {
        parseOptionLine(line) != nil
    }

    private static func parseOptionLine(_ line: String) -> ParsedOption? {
        var value = line.trimmingCharacters(in: .whitespaces)
        var selected = false
        for marker in ["❯", "›", ">"] where value.hasPrefix(marker) {
            selected = true
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard let dot = value.firstIndex(of: "."),
              value.first?.isNumber == true,
              value.distance(from: value.startIndex, to: dot) == 1,
              let number = Int(value[..<dot]) else {
            return nil
        }
        var label = String(value[value.index(after: dot)...])
            .trimmingCharacters(in: .whitespaces)
        var checked: Bool?
        if label.hasPrefix("["), let close = label.firstIndex(of: "]") {
            let mark = label[label.index(after: label.startIndex)..<close]
                .trimmingCharacters(in: .whitespaces)
            checked = mark.contains("✓") || mark.contains("✔")
                || mark.lowercased() == "x"
            label = String(label[label.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
        }
        for mark in ["✔", "✓"] where label.hasSuffix(mark) {
            selected = true
            label = String(label.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if let range = label.range(
            of: "(esc)", options: [.caseInsensitive, .backwards]) {
            label = label[..<range.lowerBound]
                .trimmingCharacters(in: .whitespaces)
        }
        guard !label.isEmpty else { return nil }
        return ParsedOption(number: number, label: label,
                            selected: selected, checked: checked)
    }
}
