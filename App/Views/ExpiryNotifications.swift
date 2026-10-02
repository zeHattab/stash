import Foundation
import UserNotifications
import StashCore

/// Локальные уведомления о сроках документов. Текст НЕЙТРАЛЬНЫЙ (без типа, имени,
/// номера, даты) — это единственные данные вне слота (см. SECURITY.md). Планирует
/// только открытый сейф; дедуп по дню.
enum ExpiryNotifications {
    static let prefix = "stash.expiry."

    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func reschedule(items: [VaultItem], enabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ours)
        guard enabled else { return }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        var days = Set<Date>()
        for item in items {
            guard let expiry = VaultAnalysis.expiryDate(of: item) else { continue }
            for lead in [90, 30, 7] {
                guard let fire = cal.date(byAdding: .day, value: -lead, to: expiry), fire > now else { continue }
                days.insert(cal.startOfDay(for: fire))
            }
        }
        for day in days.sorted().prefix(60) {
            let content = UNMutableNotificationContent()
            content.title = "Stash"
            content.body = NSLocalizedString("Проверьте сроки документов", comment: "")
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = 10
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = prefix + String(Int(day.timeIntervalSince1970))
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }
}
