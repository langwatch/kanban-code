import Foundation

/// The time label under a chat message: the time alone for a message from
/// today, day and short month before the time for an older one. Both follow
/// the locale, so a 24h phone shows 13:30 and pt-BR shows its own month.
public enum MessageTime {
    public static func label(for date: Date, now: Date = Date(),
                             locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.calendar = calendar
        let template = calendar.isDate(date, inSameDayAs: now) ? "jmm" : "dMMMjmm"
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale) ?? "HH:mm"
        return formatter.string(from: date)
    }
}
