import Foundation
import Testing
@testable import NotchApp

@Suite("AppVersion")
struct AppVersionTests {
    @Test("Numeric components order, not lexicographic strings")
    func numericOrdering() {
        #expect(AppVersion("1.10")! > AppVersion("1.9")!)
        #expect(AppVersion("2.0")! > AppVersion("1.99.99")!)
        #expect(AppVersion("0.1")! < AppVersion("0.2")!)
    }

    @Test("Trailing zeros do not change identity")
    func trailingZeros() {
        #expect(AppVersion("1.2")! == AppVersion("1.2.0")!)
        #expect(AppVersion("1.2.0.0")! == AppVersion("1.2")!)
        #expect(AppVersion("1")! == AppVersion("1.0.0")!)
        #expect(AppVersion("1.2")!.hashValue == AppVersion("1.2.0")!.hashValue)
    }

    @Test("Raw spelling round-trips for persistence")
    func rawValuePreserved() {
        #expect(AppVersion(" 1.2.3 ")!.rawValue == "1.2.3")
        #expect(AppVersion("1.2.3")!.description == "1.2.3")
    }

    @Test(
        "Non-numeric versions reject rather than compare surprisingly",
        arguments: ["", " ", "1.2.3-beta", "v1.2.3", "1..2", "1.2.", "1,2", "-1.0", "1.٢", "abc",
                    "1.2.3.4.5.6.7.8.9", "1234567890"])
    func rejectsMalformed(raw: String) {
        #expect(AppVersion(raw) == nil)
    }

    @Test("System version comes from the OS triple")
    func systemVersion() {
        let version = AppVersion.currentSystem(
            OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 1))
        #expect(version == AppVersion("14.6.1")!)
        #expect(version > AppVersion("14.0")!)
    }
}
