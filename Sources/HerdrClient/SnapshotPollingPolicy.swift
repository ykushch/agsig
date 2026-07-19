import Foundation

/// Pure cadence policy for the snapshot path. Events remain the instant
/// accelerator, while polling speeds up only when the UI or an agent is active.
public enum SnapshotPollingPolicy {
    public static func nanoseconds(
        isExpanded: Bool,
        hasBlockedPanes: Bool,
        hasWorkingPanes: Bool,
        isUnavailable: Bool
    ) -> UInt64 {
        if isUnavailable { return 1_000_000_000 }
        if isExpanded || hasBlockedPanes { return 650_000_000 }
        if hasWorkingPanes { return 1_200_000_000 }
        return 2_500_000_000
    }
}
