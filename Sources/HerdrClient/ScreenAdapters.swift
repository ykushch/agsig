import Foundation

/// Immutable terminal evidence passed to a pure screen adapter.
public struct ScreenAdapterInput: Sendable, Equatable {
    public let paneID: String
    public let agentID: String?
    public let detectionText: String
    public let visibleANSIText: String?
    public let paneRevision: UInt64?
    public let currentTabLabel: String?

    public init(paneID: String, agentID: String?, detectionText: String,
                visibleANSIText: String? = nil, paneRevision: UInt64? = nil,
                currentTabLabel: String? = nil) {
        self.paneID = paneID
        self.agentID = agentID
        self.detectionText = detectionText
        self.visibleANSIText = visibleANSIText
        self.paneRevision = paneRevision
        self.currentTabLabel = currentTabLabel
    }

    var normalizedDetectionText: String {
        detectionText.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    var revisionAsInt: Int? {
        paneRevision.flatMap(Int.init(exactly:))
    }
}

public protocol ScreenAdapter: Sendable {
    var adapterID: String { get }
    var agentIDs: Set<String> { get }
    func parse(_ input: ScreenAdapterInput) -> PendingInteraction
}

/// Case-sensitive exact-agent routing. Unknown and nil identifiers always use
/// the conservative generic adapter; they never borrow another agent's parser.
public struct ScreenAdapterRegistry: Sendable {
    private let byAgentID: [String: any ScreenAdapter]
    private let fallback: any ScreenAdapter

    public init(adapters: [any ScreenAdapter],
                fallback: any ScreenAdapter = GenericScreenAdapter()) {
        var table: [String: any ScreenAdapter] = [:]
        for adapter in adapters {
            for agentID in adapter.agentIDs where table[agentID] == nil {
                table[agentID] = adapter
            }
        }
        self.byAgentID = table
        self.fallback = fallback
    }

    public static let standard = ScreenAdapterRegistry(adapters: [
        ClaudeScreenAdapter(),
        CodexScreenAdapter(),
    ])

    public func adapterID(for agentID: String?) -> String {
        agentID.flatMap { byAgentID[$0] }?.adapterID ?? fallback.adapterID
    }

    public func parse(_ input: ScreenAdapterInput) -> PendingInteraction {
        let adapter = input.agentID.flatMap { byAgentID[$0] } ?? fallback
        return adapter.parse(input)
    }
}

public struct GenericScreenAdapter: ScreenAdapter {
    public let adapterID = "generic-screen"
    public let agentIDs: Set<String> = []

    public init() {}

    public func parse(_ input: ScreenAdapterInput) -> PendingInteraction {
        let text = input.normalizedDetectionText
        return PendingInteraction(
            paneID: input.paneID, kind: .unknown, body: text,
            presentation: InteractionPresentation(mechanism: .manual),
            capabilities: [.manualTerminal],
            evidence: InteractionEvidence(
                source: .screen, providerID: adapterID, agentID: input.agentID,
                paneRevision: input.revisionAsInt, confidence: .fallback,
                capturedText: text))
    }
}

public struct ClaudeScreenAdapter: ScreenAdapter {
    /// Declarative screen anchors derived from the committed Claude corpus.
    public static let blockMarkers = [
        "do you want to proceed?", "do you want to make this edit",
        "esc to cancel", "enter to select", "tab/arrow keys to navigate",
        "enter to select ·", "ready to submit", "you have not answered",
    ]
    public static let approvalMarkers = ["do you want to"]
    public static let denyMarkers = ["esc to cancel", "(esc)"]
    public static let navigationMarkers = ["to navigate", "↑/↓", "tab to amend"]

    public let adapterID = "claude-screen"
    public let agentIDs: Set<String> = ["claude"]

    public init() {}

    public func parse(_ input: ScreenAdapterInput) -> PendingInteraction {
        let capturedText = input.normalizedDetectionText
        guard let text = PromptClassifier.latestInteractionRegion(capturedText) else {
            return GenericScreenAdapter().parse(input)
        }
        let low = text.lowercased()
        guard Self.blockMarkers.contains(where: low.contains) else {
            return GenericScreenAdapter().parse(input)
        }
        let options = PromptClassifier.parseNumberedOptions(text)
        guard !options.isEmpty else { return GenericScreenAdapter().parse(input) }

        let isApproval = Self.approvalMarkers.contains(where: low.contains)
        let title = PromptClassifier.parseQuestionTitle(text)
        let parsedSteps = PromptClassifier.parseWizardSteps(
            text, currentLabel: input.currentTabLabel)
        let activeStepIndex = parsedSteps.firstIndex(where: \.isCurrent)
        let isSubmitReview = activeStepIndex.map { parsedSteps[$0].isSubmit } == true
            && options.contains {
                $0.label.caseInsensitiveCompare("Submit answers") == .orderedSame
            }
        let isMultiSelect = options.contains { $0.isChecked != nil }
        let mechanism: InteractionMechanism = if isMultiSelect {
            .multiSelect
        } else if Self.navigationMarkers.contains(where: low.contains),
                  options.contains(where: \.isSelected) {
            .arrowNavigate
        } else {
            .numberedShortcut
        }
        var capabilities: Set<InteractionCapability> = [
            isMultiSelect ? .selectMany : .selectOne,
        ]
        if Self.denyMarkers.contains(where: low.contains) {
            capabilities.insert(.deny)
        }
        if options.contains(where: \.isTextEntry) {
            capabilities.insert(.enterText)
        }
        if parsedSteps.count > 1 { capabilities.insert(.navigateSteps) }
        if isApproval { capabilities.insert(.approve) }

        let nonSubmitSteps = parsedSteps.filter { !$0.isSubmit }
        let progress: InteractionProgress? = nonSubmitSteps.isEmpty ? nil
            : InteractionProgress(
                current: isSubmitReview
                    ? nonSubmitSteps.count : activeStepIndex.map { $0 + 1 },
                total: nonSubmitSteps.count,
                unanswered: nonSubmitSteps.filter { !$0.isAnswered }.count)
        return PendingInteraction(
            paneID: input.paneID,
            kind: isApproval ? .approval : isSubmitReview ? .reviewSubmit : .question,
            title: title,
            body: isApproval
                ? PromptClassifier.interactionBody(text, excluding: title) : nil,
            progress: progress,
            choices: options.map {
                InteractionChoice(
                    kind: $0.isTextEntry ? .textEntry
                        : isSubmitReview
                            && $0.label.caseInsensitiveCompare("Submit answers") == .orderedSame
                            ? .submit
                            : isSubmitReview
                                && $0.label.caseInsensitiveCompare("Cancel") == .orderedSame
                                ? .cancel : .option,
                    label: $0.label, description: $0.description)
            },
            steps: parsedSteps.map {
                InteractionStep(label: $0.label, isAnswered: $0.isAnswered,
                                isSubmit: $0.isSubmit)
            },
            presentation: InteractionPresentation(
                selectedChoiceIndex: options.firstIndex(where: \.isSelected),
                checkedChoiceIndexes: options.indices.filter {
                    options[$0].isChecked == true
                },
                activeStepIndex: activeStepIndex,
                mechanism: mechanism,
                selectedChoicePreview: PromptClassifier.selectedChoicePreview(text)),
            capabilities: capabilities,
            evidence: InteractionEvidence(
                source: .screen, providerID: adapterID,
                agentID: input.agentID, paneRevision: input.revisionAsInt,
                confidence: .exact, capturedText: capturedText),
            contentEvidence: Self.parseDiffEvidence(text))
    }

    private static func parseDiffEvidence(_ text: String) -> InteractionContentEvidence? {
        let lines = text.components(separatedBy: "\n")
        guard let header = lines.lastIndex(where: { trimmed($0) == "Edit file" }),
              lines.indices.contains(header + 1) else { return nil }
        let filePath = trimmed(lines[header + 1])
        guard !filePath.isEmpty,
              let firstRule = lines.indices.first(where: {
                  $0 > header + 1 && isDiffRule(lines[$0])
              }),
              let secondRule = lines.indices.first(where: {
                  $0 > firstRule && isDiffRule(lines[$0])
              }) else { return nil }

        let parsed = lines[(firstRule + 1)..<secondRule].compactMap(parseDiffLine)
        guard !parsed.isEmpty,
              parsed.contains(where: { $0.kind != InteractionDiffLineKind.context }) else {
            return nil
        }
        return .diff(InteractionDiffEvidence(filePath: filePath, lines: parsed))
    }

    private static func isDiffRule(_ line: String) -> Bool {
        let value = trimmed(line)
        return value.count >= 8 && value.allSatisfy { $0 == "╌" }
    }

    private static func parseDiffLine(_ line: String) -> InteractionDiffLine? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^\s*(\d+)\s+([+-]?)(.*)$"#),
              let match = regex.firstMatch(
                in: line, range: NSRange(line.startIndex..., in: line)),
              let numberRange = Range(match.range(at: 1), in: line),
              let number = Int(line[numberRange]),
              let markerRange = Range(match.range(at: 2), in: line),
              let textRange = Range(match.range(at: 3), in: line) else { return nil }
        let kind: InteractionDiffLineKind = switch line[markerRange] {
        case "-": .removal
        case "+": .addition
        default: .context
        }
        return InteractionDiffLine(lineNumber: number, kind: kind,
                                   text: String(line[textRange]))
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct CodexScreenAdapter: ScreenAdapter {
    /// Declarative anchors from the verified M0C Codex corpus. Shape-specific
    /// parsing below only runs after one of these complete screen signatures.
    public enum Markers {
        public static let questionHeader = #"^\s*Question\s+\d+/\d+(?:\s+\(\d+\s+unanswered\))?\s*$"#
        public static let addNotes = "tab to add notes"
        public static let submitAll = "enter to submit all"
        public static let questionFooters = [
            "tab to add notes | enter to submit answer",
            "tab to add notes | enter to submit all",
            "tab or esc to clear notes | enter to submit all",
        ]
        public static let notesFocus = "› add notes"
        public static let reviewTitle = "Submit with unanswered questions?"
        public static let reviewFooter = "press enter to confirm or esc to go back"
        public static let approvalTitle = "Would you like to run the following command?"
        public static let approvalFooter = "press enter to confirm or esc to cancel"
    }

    public let adapterID = "codex-screen"
    public let agentIDs: Set<String> = ["codex"]

    public init() {}

    public func parse(_ input: ScreenAdapterInput) -> PendingInteraction {
        let text = input.normalizedDetectionText
        let low = text.lowercased()
        let interaction: PendingInteraction?
        if low.contains(Markers.approvalTitle.lowercased()), low.contains(Markers.approvalFooter) {
            interaction = parseApproval(input, text: text)
        } else if low.contains(Markers.reviewTitle.lowercased()), low.contains(Markers.reviewFooter) {
            interaction = parseReview(input, text: text)
        } else if Markers.questionFooters.contains(where: low.contains) {
            interaction = parseQuestion(input, text: text)
        } else {
            interaction = nil
        }

        return interaction ?? GenericScreenAdapter().parse(input)
    }

    private func parseQuestion(_ input: ScreenAdapterInput, text: String) -> PendingInteraction? {
        let lines = text.components(separatedBy: "\n")
        guard let headerIndex = lines.firstIndex(where: { Self.matches(Markers.questionHeader, $0) }),
              let progress = Self.parseQuestionProgress(lines[headerIndex]),
              let title = lines.dropFirst(headerIndex + 1).map(Self.trimmed)
                .first(where: { !$0.isEmpty && !$0.hasPrefix("›") }) else { return nil }
        let parsedOptions = Self.parseOptions(lines)
        guard !parsedOptions.isEmpty else { return nil }

        let low = text.lowercased()
        let isNotes = low.contains(Markers.notesFocus)
        let kind: InteractionKind = progress.unanswered == nil && low.contains(Markers.submitAll)
            ? .reviewSubmit : .question
        var capabilities: Set<InteractionCapability> = [.selectOne, .deny]
        if low.contains(Markers.addNotes) || isNotes { capabilities.insert(.enterText) }
        if (progress.total ?? 0) > 1 { capabilities.insert(.navigateSteps) }
        return PendingInteraction(
            paneID: input.paneID, kind: kind, title: title, progress: progress,
            choices: parsedOptions.map { InteractionChoice(label: $0.label, description: $0.description) },
            presentation: InteractionPresentation(
                selectedChoiceIndex: parsedOptions.firstIndex(where: \.selected),
                mechanism: isNotes ? .textEntry : .arrowNavigate),
            capabilities: capabilities,
            evidence: Self.evidence(input, adapterID: adapterID, text: text))
    }

    private func parseReview(_ input: ScreenAdapterInput, text: String) -> PendingInteraction? {
        let lines = text.components(separatedBy: "\n")
        let options = Self.parseOptions(lines)
        guard options.count == 2 else { return nil }
        let unanswered = lines.compactMap { line -> Int? in
            let words = Self.trimmed(line).split(separator: " ")
            guard words.count == 3, words[1] == "unanswered", words[2] == "questions" else { return nil }
            return Int(words[0])
        }.first
        return PendingInteraction(
            paneID: input.paneID, kind: .reviewSubmit,
            title: Markers.reviewTitle,
            progress: InteractionProgress(unanswered: unanswered),
            choices: options.map { InteractionChoice(label: $0.label, description: $0.description) },
            presentation: InteractionPresentation(
                selectedChoiceIndex: options.firstIndex(where: \.selected),
                mechanism: .arrowNavigate),
            capabilities: [.selectOne, .deny],
            evidence: Self.evidence(input, adapterID: adapterID, text: text))
    }

    private func parseApproval(_ input: ScreenAdapterInput, text: String) -> PendingInteraction? {
        let lines = text.components(separatedBy: "\n")
        guard let titleIndex = lines.lastIndex(where: {
            Self.trimmed($0).lowercased() == Markers.approvalTitle.lowercased()
        }), let footerIndex = lines.indices.first(where: {
            $0 > titleIndex && $0 < lines.endIndex
                && lines[$0].lowercased().contains(Markers.approvalFooter)
        }) else { return nil }
        let approvalLines = Array(lines[titleIndex...footerIndex])
        let raw = Self.parseApprovalOptions(approvalLines)
        guard raw.count == 3 else { return nil }
        let verifiedShortcuts = raw.map(\.shortcutKey) == ["y", "p", "esc"]
        let choices = raw.enumerated().map { index, option in
            let label: String
            let description: String
            switch index {
            case 0:
                label = Self.removingShortcut(option.label)
                description = "Run once."
            case 1:
                label = option.label.components(separatedBy: " for commands that start with").first
                    .map(Self.removingShortcut) ?? option.label
                description = Self.commandPrefix(in: option.label).map {
                    "Persist approval for commands starting with `\($0)`."
                } ?? "Persist approval for the exact command prefix."
            default:
                label = Self.removingShortcut(option.label)
                description = "Deny and return feedback to Codex."
            }
            return InteractionChoice(
                label: label, description: description,
                shortcutKeys: verifiedShortcuts ? option.shortcutKey.map { [$0] } ?? [] : [])
        }
        guard let firstOptionIndex = approvalLines.indices.first(where: {
            $0 > approvalLines.startIndex && Self.isOptionLine(approvalLines[$0])
        }) else { return nil }
        let body = approvalLines[(approvalLines.startIndex + 1)..<firstOptionIndex]
            .map(Self.trimmed).filter { !$0.isEmpty }.joined(separator: "\n")
        return PendingInteraction(
            paneID: input.paneID, kind: .approval,
            title: Markers.approvalTitle, body: body,
            choices: choices,
            presentation: InteractionPresentation(
                selectedChoiceIndex: raw.firstIndex(where: \.selected),
                mechanism: verifiedShortcuts ? .explicitShortcut : .ambiguous),
            capabilities: [.approve, .deny, .selectOne],
            evidence: Self.evidence(input, adapterID: adapterID, text: text),
            contentEvidence: Self.parseCommandEvidence(approvalLines))
    }

    private static func parseCommandEvidence(
        _ lines: [String]
    ) -> InteractionContentEvidence? {
        func value(after prefix: String) -> String? {
            lines.lazy.map(trimmed).first { $0.hasPrefix(prefix) }.map {
                trimmed(String($0.dropFirst(prefix.count)))
            }.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let command = value(after: "$ ") else { return nil }
        return .command(InteractionCommandEvidence(
            environment: value(after: "Environment:"),
            reason: value(after: "Reason:"), command: command))
    }

    private struct ParsedOption {
        let label: String
        let description: String?
        let selected: Bool
        let shortcutKey: String?
    }

    private static func parseOptions(_ lines: [String]) -> [ParsedOption] {
        lines.compactMap { line in
            var value = trimmed(line)
            var selected = false
            for marker in ["❯", "›", ">"] where value.hasPrefix(marker) {
                selected = true
                value = trimmed(String(value.dropFirst()))
            }
            guard let dot = value.firstIndex(of: "."),
                  let number = Int(value[..<dot]), number > 0 else { return nil }
            let remainder = trimmed(String(value[value.index(after: dot)...]))
            guard !remainder.isEmpty else { return nil }
            let separator = remainder.range(of: #"\s{2,}"#, options: .regularExpression)
            let label = separator.map { trimmed(String(remainder[..<$0.lowerBound])) } ?? remainder
            let description = separator.map { trimmed(String(remainder[$0.upperBound...])) }
            return ParsedOption(label: label,
                                description: description?.isEmpty == false ? description : nil,
                                selected: selected, shortcutKey: nil)
        }
    }

    /// Approval options can wrap in the middle of a backticked command prefix.
    /// Reassemble each numbered block before trusting its advertised shortcut.
    private static func parseApprovalOptions(_ lines: [String]) -> [ParsedOption] {
        struct Start {
            let lineIndex: Int
            let number: Int
            let selected: Bool
            let remainder: String
        }
        var starts: [Start] = []
        for (lineIndex, line) in lines.enumerated() {
            var value = trimmed(line)
            var selected = false
            for marker in ["❯", "›", ">"] where value.hasPrefix(marker) {
                selected = true
                value = trimmed(String(value.dropFirst()))
            }
            guard let dot = value.firstIndex(of: "."),
                  let number = Int(value[..<dot]), number > 0 else { continue }
            let remainder = trimmed(String(value[value.index(after: dot)...]))
            guard !remainder.isEmpty else { continue }
            starts.append(Start(lineIndex: lineIndex, number: number,
                                selected: selected, remainder: remainder))
        }
        guard starts.map(\.number) == [1, 2, 3] else { return [] }

        return starts.enumerated().map { offset, start in
            let nextStart = starts.indices.contains(offset + 1)
                ? starts[offset + 1].lineIndex : lines.count
            let footer = lines.indices.first {
                $0 > start.lineIndex && $0 < nextStart
                    && lines[$0].lowercased().contains(Markers.approvalFooter)
            } ?? nextStart
            var label = start.remainder
            for continuation in lines[(start.lineIndex + 1)..<footer].map(trimmed)
                where !continuation.isEmpty {
                let insideBackticks = label.filter { $0 == "`" }.count.isMultiple(of: 2) == false
                label += (insideBackticks ? "" : " ") + continuation
            }
            return ParsedOption(
                label: label, description: nil, selected: start.selected,
                shortcutKey: trailingShortcut(in: label))
        }
    }

    private static func trailingShortcut(in value: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\((y|p|esc)\)\s*$"#, options: .caseInsensitive),
              let match = regex.firstMatch(
                in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return value[range].lowercased()
    }

    private static func commandPrefix(in value: String) -> String? {
        guard let start = value.firstIndex(of: "`"),
              let end = value[value.index(after: start)...].firstIndex(of: "`") else {
            return nil
        }
        let prefix = String(value[value.index(after: start)..<end])
        return prefix.isEmpty ? nil : prefix
    }

    private static func parseQuestionProgress(_ line: String) -> InteractionProgress? {
        guard let regex = try? NSRegularExpression(
            pattern: #"Question\s+(\d+)/(\d+)(?:\s+\((\d+)\s+unanswered\))?"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let current = integerCapture(1, match: match, in: line),
              let total = integerCapture(2, match: match, in: line) else { return nil }
        return InteractionProgress(current: current, total: total,
                                   unanswered: integerCapture(3, match: match, in: line))
    }

    private static func integerCapture(_ index: Int, match: NSTextCheckingResult,
                                       in value: String) -> Int? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return nil }
        return Int(value[swiftRange])
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isOptionLine(_ value: String) -> Bool {
        var line = trimmed(value)
        for marker in ["❯", "›", ">"] where line.hasPrefix(marker) {
            line = trimmed(String(line.dropFirst()))
        }
        guard let dot = line.firstIndex(of: ".") else { return false }
        return Int(line[..<dot]) != nil
    }

    private static func removingShortcut(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+\((?:y|p)\)$"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+\(esc\)$"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func evidence(_ input: ScreenAdapterInput, adapterID: String,
                                 text: String) -> InteractionEvidence {
        InteractionEvidence(source: .screen, providerID: adapterID,
                            agentID: input.agentID, paneRevision: input.revisionAsInt,
                            confidence: .exact, capturedText: text)
    }
}
