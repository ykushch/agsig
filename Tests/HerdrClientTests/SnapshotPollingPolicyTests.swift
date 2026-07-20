import Testing
@testable import HerdrClient

@Suite("Adaptive snapshot polling")
struct SnapshotPollingPolicyTests {
    @Test("activity, attention, and recovery select bounded cadences")
    func cadence() {
        #expect(SnapshotPollingPolicy.nanoseconds(
            isExpanded: false, hasBlockedPanes: false,
            hasWorkingPanes: false, isUnavailable: false) == 2_500_000_000)
        #expect(SnapshotPollingPolicy.nanoseconds(
            isExpanded: false, hasBlockedPanes: false,
            hasWorkingPanes: true, isUnavailable: false) == 1_200_000_000)
        #expect(SnapshotPollingPolicy.nanoseconds(
            isExpanded: false, hasBlockedPanes: true,
            hasWorkingPanes: false, isUnavailable: false) == 650_000_000)
        #expect(SnapshotPollingPolicy.nanoseconds(
            isExpanded: true, hasBlockedPanes: false,
            hasWorkingPanes: false, isUnavailable: false) == 650_000_000)
        #expect(SnapshotPollingPolicy.nanoseconds(
            isExpanded: true, hasBlockedPanes: true,
            hasWorkingPanes: true, isUnavailable: true) == 1_000_000_000)
    }
}
