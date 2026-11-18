import Foundation
import XCTest
@testable import QuotaBar

final class MenuBarEntryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_700_000)

    func testStandardSlotsUseTheSamePrefixesAcrossProviders() {
        for provider in [Provider.codex, .claude, .antigravity] {
            let entry = MenuBarEntry(provider: provider,
                session: MenuBarQuota(remaining: 80, resetsAt: nil),
                weekly: MenuBarQuota(remaining: 34, resetsAt: nil))

            XCTAssertEqual(entry.menuLabel(at: now), "5h80%/w34%")
        }
    }

    func testNoLimitAndUnavailableSlotsKeepTheirLabels() {
        let entry = MenuBarEntry(provider: .codex,
            session: MenuBarQuota(limit: .noLimit), weekly: MenuBarQuota(limit: .unavailable))

        XCTAssertEqual(entry.menuLabel(at: now), "5h∞/w-")
    }

    func testFableAppearsBesideStandardClaudePercentages() {
        let entry = MenuBarEntry(provider: .claude,
            session: MenuBarQuota(remaining: 80, resetsAt: nil),
            weekly: MenuBarQuota(remaining: 34, resetsAt: nil),
            fable: MenuBarQuota(remaining: 42, resetsAt: nil))

        XCTAssertEqual(entry.menuLabel(at: now), "5h80%/w34%/F42%")
        XCTAssertEqual(entry.menuSegments(at: now).last?.remaining, 42)
        XCTAssertTrue(entry.description(at: now).contains("Fable weekly window: 42% left"))
    }

    func testFableCountdownDisappearsAtResetTime() {
        let expiry = now.addingTimeInterval(3600)
        let entry = MenuBarEntry(provider: .claude,
            session: MenuBarQuota(remaining: 80, resetsAt: nil),
            weekly: MenuBarQuota(remaining: 34, resetsAt: nil),
            fable: MenuBarQuota(remaining: 0, resetsAt: expiry))

        XCTAssertEqual(entry.menuLabel(at: now), "5h80%/w34%/F1h0m")
        XCTAssertEqual(entry.menuLabel(at: expiry), "5h80%/w34%")
        XCTAssertFalse(entry.description(at: expiry).contains("Fable"))
    }

    func testExhaustedStandardWeeklyWindowStillShowsOnlyItsCountdown() {
        let entry = MenuBarEntry(provider: .claude,
            session: MenuBarQuota(remaining: 80, resetsAt: nil),
            weekly: MenuBarQuota(remaining: 0, resetsAt: now.addingTimeInterval(3600)),
            fable: MenuBarQuota(remaining: 42, resetsAt: nil))

        XCTAssertEqual(entry.menuLabel(at: now), "1h0m")
    }
}
