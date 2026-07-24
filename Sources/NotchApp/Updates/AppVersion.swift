import Foundation

/// A release version expressed as numeric dot-separated components — the exact
/// shape `bundle.sh` enforces for `VERSION` and the release workflow enforces
/// for tags. Comparison pads the shorter side with zeros, so `1.2 == 1.2.0` and
/// `1.10 > 1.9` (a plain string compare gets that last one wrong).
struct AppVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The parsed numeric components, most significant first.
    let components: [Int]
    /// The original string, preserved so persisted values round-trip exactly.
    let rawValue: String

    /// Fails on anything that is not `1`, `1.2`, `1.2.3`, … — empty strings,
    /// negative numbers, pre-release suffixes, and non-ASCII digits all reject
    /// rather than silently comparing as something surprising.
    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty, (1...8).contains(parts.count) else { return nil }

        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            guard (1...9).contains(part.count),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part)
            else { return nil }
            parsed.append(value)
        }
        components = parsed
        rawValue = trimmed
    }

    /// The version of a bundled app. `nil` for the bare `swift run` executable,
    /// which has no `Info.plist` — one of the signals that suppresses checking.
    static func current(bundle: Bundle = .main) -> AppVersion? {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(AppVersion.init)
    }

    /// The running macOS version, for comparing against `minimumSystemVersion`.
    static func currentSystem(
        _ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> AppVersion {
        AppVersion("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
            ?? AppVersion("0")!
    }

    var description: String { rawValue }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// Equality is by value, not by spelling: `1.2` and `1.2.0` are the same
    /// release even though their `rawValue`s differ.
    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    func hash(into hasher: inout Hasher) {
        var normalized = components
        while normalized.count > 1, normalized.last == 0 { normalized.removeLast() }
        hasher.combine(normalized)
    }
}
