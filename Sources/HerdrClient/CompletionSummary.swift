import Foundation

public protocol CompletionSummaryProviding: Sendable {
    func completionSummary(paneID: String) async throws -> String?
}

/// Reads a bounded, unwrapped terminal tail exactly once per finished
/// transition. Extraction remains pure so real terminal captures can serve as
/// its regression corpus without a live herdr dependency.
public struct ScreenCompletionSummaryProvider: CompletionSummaryProviding, Sendable {
    private let client: any RequestSending
    private let lineLimit: Int

    public init(client: any RequestSending, lineLimit: Int = 80) {
        self.client = client
        self.lineLimit = max(1, lineLimit)
    }

    public func completionSummary(paneID: String) async throws -> String? {
        let params = try PaneReadParams(
            paneID: paneID, source: .recentUnwrapped, lines: lineLimit,
            format: "text", stripAnsi: true).asJSONValue()
        let result = try await client.request("pane.read", params: params)
        guard let value = result["read"],
              let read = try? value.decode(PaneReadResult.self) else {
            throw InteractionProviderError.unreadablePane(paneID: paneID)
        }
        return CompletionSummaryExtractor.extract(from: read.text)
    }
}

public enum CompletionSummaryExtractor {
    private static let toolPrefixes = [
        "ran ", "running ", "read ", "searched ", "edited ", "wrote ",
        "explored ", "working ", "you have ", "i’m requesting approval",
        "i'm requesting approval",
    ]

    public static func extract(from terminalText: String,
                               characterLimit: Int = 280) -> String? {
        let normalized = PromptClassifier.stripAnsi(terminalText)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")

        if let promptIndex = lines.lastIndex(where: { line in
            let value = trimmed(line)
            return value.hasPrefix("›") || value.hasPrefix("❯")
        }) {
            lines = Array(lines[..<promptIndex])
        }
        while let last = lines.last, !isMeaningful(last) { lines.removeLast() }
        guard !lines.isEmpty else { return nil }

        let assistantStart = lines.indices.reversed().first { index in
            let value = trimmed(lines[index])
            guard value.hasPrefix("• ") || value.hasPrefix("● ") else { return false }
            let content = String(value.dropFirst(2)).lowercased()
            return !toolPrefixes.contains(where: content.hasPrefix)
        }

        let selected: ArraySlice<String>
        if let assistantStart {
            selected = lines[assistantStart...]
        } else {
            let paragraphStart = lines.indices.reversed().first {
                $0 < lines.index(before: lines.endIndex) && trimmed(lines[$0]).isEmpty
            }.map { lines.index(after: $0) } ?? lines.startIndex
            selected = lines[paragraphStart...]
            if let first = selected.first {
                var content = trimmed(first)
                for marker in ["• ", "● "] where content.hasPrefix(marker) {
                    content.removeFirst(marker.count)
                }
                if toolPrefixes.contains(where: content.lowercased().hasPrefix) {
                    return nil
                }
            }
        }

        var summary = selected.map(trimmed).filter(isMeaningful)
            .joined(separator: " ")
        for marker in ["• ", "● "] where summary.hasPrefix(marker) {
            summary.removeFirst(marker.count)
        }
        summary = summary.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !summary.isEmpty, !summary.hasPrefix("└") else { return nil }

        let limit = max(1, characterLimit)
        guard summary.count > limit else { return summary }
        let end = summary.index(summary.startIndex, offsetBy: limit - 1)
        return String(summary[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isMeaningful(_ line: String) -> Bool {
        let value = trimmed(line)
        guard !value.isEmpty, !value.hasPrefix("└") else { return false }
        return value.contains { !$0.isWhitespace && !"─━═".contains($0) }
    }
}
