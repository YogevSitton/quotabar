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

            XCTAssertEqual(entry.menuLabel(at: now), "h80%/w34%")
        }
    }

    func testWeeklyOnlyReadingOmitsFiveHourSlotAndSpokenDescription() {
        for provider in [Provider.codex, .claude] {
            let entry = MenuBarEntry(provider: provider, session: MenuBarQuota(limit: .noLimit),
                weekly: MenuBarQuota(remaining: 61, resetsAt: nil))

            XCTAssertEqual(entry.menuLabel(at: now), "w61%")
            XCTAssertEqual(entry.description(at: now), "\(provider.rawValue); Weekly window: 61% left · reset not reported")
        }
    }

    func testUnavailableFiveHourWindowKeepsItsSlot() {
        let entry = MenuBarEntry(provider: .claude, session: MenuBarQuota(limit: .unavailable),
            weekly: MenuBarQuota(remaining: 61, resetsAt: nil))
        XCTAssertEqual(entry.menuLabel(at: now), "h-/w61%")
        XCTAssertTrue(entry.description(at: now).contains("5-hour window: Unavailable"))
    }

    func testWeeklyOnlyReadingKeepsWeeklyCountdownFableAndExpiryChip() {
        let entry = MenuBarEntry(provider: .claude, session: MenuBarQuota(limit: .noLimit),
            weekly: MenuBarQuota(remaining: 61, resetsAt: now.addingTimeInterval(7200)),
            nextResetExpiry: now.addingTimeInterval(2 * 86400), fable: MenuBarQuota(remaining: 42, resetsAt: nil))
        XCTAssertEqual(entry.menuLabel(at: now), "w61%2h/F42% 2d")
        XCTAssertEqual(entry.menuSegments(at: now).filter(\.isLeftover).map(\.text), ["2h"])
    }

    func testFableAppearsBesideStandardClaudePercentages() {
        let entry = MenuBarEntry(provider: .claude,
            session: MenuBarQuota(remaining: 80, resetsAt: nil),
            weekly: MenuBarQuota(remaining: 34, resetsAt: nil),
            fable: MenuBarQuota(remaining: 42, resetsAt: nil))

        XCTAssertEqual(entry.menuLabel(at: now), "h80%/w34%/F42%")
        XCTAssertEqual(entry.menuSegments(at: now).last?.remaining, 42)
        XCTAssertTrue(entry.description(at: now).contains("Fable weekly window: 42% left"))
    }

    func testFableCountdownDisappearsAtResetTime() {
        let expiry = now.addingTimeInterval(3600)
        let entry = MenuBarEntry(provider: .claude,
            session: MenuBarQuota(remaining: 80, resetsAt: nil),
            weekly: MenuBarQuota(remaining: 34, resetsAt: nil),
            fable: MenuBarQuota(remaining: 0, resetsAt: expiry))

        XCTAssertEqual(entry.menuLabel(at: now), "h80%/w34%/F1h0m")
        XCTAssertEqual(entry.menuLabel(at: expiry), "h80%/w34%")
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
