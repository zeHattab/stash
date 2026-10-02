import Foundation

/// Чистое планирование уведомлений о сроках — без UNUserNotificationCenter, тестируется.
/// Идентификаторы ПРИВЯЗАНЫ к сейфу через непрозрачный тег (хэш соли слота), поэтому
/// перепланирование в одном сейфе НЕ трогает уведомления другого (настоящего/ложного).
public enum ExpiryNotificationPlan {

    public static let rootPrefix = "stash.expiry."

    /// Префикс идентификаторов для конкретного сейфа.
    public static func prefix(tag: String) -> String { rootPrefix + tag + "." }

    public struct Request: Equatable, Sendable {
        public let identifier: String
        public let year: Int
        public let month: Int
        public let day: Int
        public let hour: Int
        public init(identifier: String, year: Int, month: Int, day: Int, hour: Int) {
            self.identifier = identifier; self.year = year; self.month = month
            self.day = day; self.hour = hour
        }
    }

    /// Какие из существующих идентификаторов принадлежат ЭТОМУ сейфу и должны быть сняты.
    /// Чужие (другой тег) и посторонние идентификаторы не трогаем.
    public static func identifiersToRemove(existing: [String], tag: String) -> [String] {
        let p = prefix(tag: tag)
        return existing.filter { $0.hasPrefix(p) }
    }

    /// План уведомлений: за `leads` дней до каждого срока, только будущие, дедуп по дню, с потолком.
    public static func requests(
        expiryDates: [Date],
        tag: String,
        now: Date,
        calendar: Calendar,
        leads: [Int] = [90, 30, 7],
        hour: Int = 10,
        cap: Int = 60
    ) -> [Request] {
        let p = prefix(tag: tag)
        var days = Set<Date>()
        for expiry in expiryDates {
            for lead in leads {
                guard let fire = calendar.date(byAdding: .day, value: -lead, to: expiry),
                      fire > now else { continue }
                days.insert(calendar.startOfDay(for: fire))
            }
        }
        return days.sorted().prefix(cap).map { day in
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let id = p + String(Int(day.timeIntervalSince1970))
            return Request(identifier: id, year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0, hour: hour)
        }
    }
}
