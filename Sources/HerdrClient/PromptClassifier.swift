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

    static func parseQuestionTitle(_ text: String) -> String? {
        let lines = text.split(
            separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstOption = lines.firstIndex(where: isOptionLine) else {
            return nil
        }
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
            return value
        }
        return nil
    }

    static func parseNumberedOptions(_ text: String) -> [ParsedTerminalOption] {
        let lines = text.split(
            separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var options: [ParsedTerminalOption] = []
        var index = 0
        while index < lines.count {
            guard let parsed = parseOptionLine(lines[index]) else {
                index += 1
                continue
            }
            var description: String?
            if index + 1 < lines.count {
                let next = lines[index + 1]
                let trimmed = next.trimmingCharacters(in: .whitespaces)
                let isIndented = next.hasPrefix("  ") || next.hasPrefix("\t")
                let isHint = trimmed.isEmpty
                    || trimmed.allSatisfy { $0 == "─" || $0 == "—" || $0 == "-" }
                    || trimmed.lowercased().contains("to select")
                    || trimmed.lowercased().contains("to navigate")
                if parseOptionLine(next) == nil, isIndented, !isHint {
                    description = trimmed
                }
            }
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
              value.distance(from: value.startIndex, to: dot) == 1 else {
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
        return ParsedOption(label: label, selected: selected, checked: checked)
    }
}
