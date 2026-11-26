import Foundation
import Testing
@testable import KanbanCodeRemoteKit

@Suite("MessageTime")
struct MessageTimeTests {
    let utc = TimeZone(identifier: "UTC")!
    /// 2026-11-26 15:00 UTC.
    let now = Date(timeIntervalSince1970: 1_795_705_200)

    private func at(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: s)!
    }

    @Test func todayShowsTimeOnly24h() {
        let label = MessageTime.label(for: at("2026-11-26T13:30:00Z"), now: now,
                                      locale: Locale(identifier: "en_GB"), timeZone: utc)
        #expect(label == "13:30")
    }

    @Test func todayShowsTimeOnly12h() {
        let label = MessageTime.label(for: at("2026-11-26T13:30:00Z"), now: now,
                                      locale: Locale(identifier: "en_US"), timeZone: utc)
        #expect(label.contains("1:30"))
        #expect(label.contains("PM"))
        #expect(!label.contains("Nov"))
    }

    @Test func olderShowsDayAndShortMonth() {
        let label = MessageTime.label(for: at("2026-08-27T13:30:00Z"), now: now,
                                      locale: Locale(identifier: "en_GB"), timeZone: utc)
        #expect(label.contains("27 Aug"))
        #expect(label.contains("13:30"))
    }

    @Test func olderInPortugueseUsesItsMonth() {
        let label = MessageTime.label(for: at("2026-08-27T13:30:00Z"), now: now,
                                      locale: Locale(identifier: "pt_BR"), timeZone: utc)
        #expect(label.contains("27"))
        #expect(label.contains("ago"))
        #expect(label.contains("13:30"))
    }

    @Test func yesterdayLateIsNotToday() {
        let label = MessageTime.label(for: at("2026-11-25T23:59:00Z"), now: now,
                                      locale: Locale(identifier: "en_GB"), timeZone: utc)
        #expect(label.contains("25 Nov"))
    }

    @Test func dayFollowsTheTimeZone() {
        // 23:30 UTC on the 26th is already the 27th in Amsterdam, and "now"
        // there is 16:00 on the 26th, so it is not today.
        let ams = TimeZone(identifier: "Europe/Amsterdam")!
        let label = MessageTime.label(for: at("2026-11-26T23:30:00Z"), now: now,
                                      locale: Locale(identifier: "en_GB"), timeZone: ams)
        #expect(label.contains("27 Nov"))
        #expect(label.contains("00:30"))
    }
}
