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

/// Both representations exist temporarily: normalized consumers use
/// `interaction`; the current Claude UI continues to use `legacyPrompt`.
public struct ScreenAdapterResult: Sendable, Equatable {
    public let interaction: PendingInteraction
    public let legacyPrompt: ClassifiedPrompt

    public init(interaction: PendingInteraction, legacyPrompt: ClassifiedPrompt) {
        self.interaction = interaction
        self.legacyPrompt = legacyPrompt
    }
}

public protocol ScreenAdapter: Sendable {
    var adapterID: String { get }
    var agentIDs: Set<String> { get }
    func parse(_ input: ScreenAdapterInput) -> ScreenAdapterResult
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

    public func parse(_ input: ScreenAdapterInput) -> ScreenAdapterResult {
        let adapter = input.agentID.flatMap { byAgentID[$0] } ?? fallback
        return adapter.parse(input)
    }
}

public struct GenericScreenAdapter: ScreenAdapter {
    public let adapterID = "generic-screen"
    public let agentIDs: Set<String> = []

    public init() {}

    public func parse(_ input: ScreenAdapterInput) -> ScreenAdapterResult {
        let text = input.normalizedDetectionText
        let legacy = ClassifiedPrompt.rawFallback(text)
        let interaction = PendingInteraction(
            paneID: input.paneID, kind: .unknown, body: text,
            presentation: InteractionPresentation(mechanism: .manual),
            capabilities: [.manualTerminal],
            evidence: InteractionEvidence(
                source: .screen, providerID: adapterID, agentID: input.agentID,
                paneRevision: input.revisionAsInt, confidence: .fallback,
                capturedText: text))
        return ScreenAdapterResult(interaction: interaction, legacyPrompt: legacy)
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
    public static let navigationMarkers = ["to navigate", "↑/↓"]

    public let adapterID = "claude-screen"
    public let agentIDs: Set<String> = ["claude"]

    public init() {}

    public func parse(_ input: ScreenAdapterInput) -> ScreenAdapterResult {
        let text = input.normalizedDetectionText
        let low = text.lowercased()
        guard Self.blockMarkers.contains(where: low.contains) else {
            return GenericScreenAdapter().parse(input)
        }
        let options = PromptClassifier.parseNumberedOptions(text)
        guard !options.isEmpty else { return GenericScreenAdapter().parse(input) }

        let isApproval = Self.approvalMarkers.contains(where: low.contains)
        let prompt = ClassifiedPrompt(
            kind: isApproval ? .approval : .question,
            options: options,
            denyKeys: Self.denyMarkers.contains(where: low.contains) ? ["esc"] : [],
            promptText: text,
            isMarkdown: PromptClassifier.looksLikeMarkdown(text),
            questionTitle: isApproval ? nil : PromptClassifier.parseQuestionTitle(text),
            steps: PromptClassifier.parseWizardSteps(text, currentLabel: input.currentTabLabel),
            answerStyle: (Self.navigationMarkers.contains(where: low.contains)
                && options.contains(where: \.isSelected)) ? .arrowNavigate : .numberedShortcut,
            isMultiSelect: options.contains { $0.isChecked != nil })
        let interaction = PendingInteraction(
            paneID: input.paneID, classifiedPrompt: prompt,
            agentID: input.agentID, paneRevision: input.revisionAsInt,
            providerID: adapterID, confidence: .exact)
        return ScreenAdapterResult(interaction: interaction, legacyPrompt: prompt)
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

    public func parse(_ input: ScreenAdapterInput) -> ScreenAdapterResult {
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

        guard let interaction else { return GenericScreenAdapter().parse(input) }
        // M2 extracts Codex structure but deliberately leaves the old UI raw.
        return ScreenAdapterResult(
            interaction: interaction, legacyPrompt: ClassifiedPrompt.rawFallback(text))
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
        let raw = Self.parseOptions(lines)
        guard raw.count == 3 else { return nil }
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
                description = "Persist approval for the exact command prefix."
            default:
                label = Self.removingShortcut(option.label)
                description = "Deny and return feedback to Codex."
            }
            return InteractionChoice(label: label, description: description)
        }
        let body = lines.map(Self.trimmed).filter { line in
            !line.isEmpty && line.lowercased() != Markers.approvalTitle.lowercased()
                && !Self.isOptionLine(line) && !line.lowercased().contains(Markers.approvalFooter)
        }.joined(separator: "\n")
        return PendingInteraction(
            paneID: input.paneID, kind: .approval,
            title: Markers.approvalTitle, body: body,
            choices: choices,
            presentation: InteractionPresentation(
                selectedChoiceIndex: raw.firstIndex(where: \.selected), mechanism: .ambiguous),
            capabilities: [.approve, .deny, .selectOne],
            evidence: Self.evidence(input, adapterID: adapterID, text: text))
    }

    private struct ParsedOption {
        let label: String
        let description: String?
        let selected: Bool
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
                                selected: selected)
        }
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
