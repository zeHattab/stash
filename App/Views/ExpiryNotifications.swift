import Foundation
import UserNotifications
import StashCore

/// Локальные уведомления о сроках документов. Текст НЕЙТРАЛЬНЫЙ (без типа, имени,
/// номера, даты) — это единственные данные вне слота (см. SECURITY.md). Планирует
/// только открытый сейф; идентификаторы ПРИВЯЗАНЫ к сейфу через непрозрачный тег,
/// поэтому перепланирование не трогает уведомления другого сейфа (планирование —
/// в StashCore `ExpiryNotificationPlan`, тестируется).
enum ExpiryNotifications {

    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Ключ флага разовой миграции меток (соль→ключ).
    private static let migrationKey = "notifTagV1Migrated"

    static func reschedule(items: [VaultItem], enabled: Bool, tag: String?) async {
        guard let tag else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier)

        // Разовая миграция: старые метки выводились из соли (лежит в файле открыто).
        // Снимаем ВСЕ прежние уведомления о сроках один раз — каждый сейф перепланирует
        // свои с новой меткой (из ключа) при открытии.
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            let old = pending.filter { $0.hasPrefix(ExpiryNotificationPlan.rootPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            UserDefaults.standard.set(true, forKey: migrationKey)
        } else {
            // Снимаем ТОЛЬКО свои (этого сейфа) — чужие и посторонние не трогаем.
            let ours = ExpiryNotificationPlan.identifiersToRemove(existing: pending, tag: tag)
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }
        guard enabled else { return }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let dates = items.compactMap { VaultAnalysis.expiryDate(of: $0) }
        let cal = Calendar(identifier: .gregorian)
        let requests = ExpiryNotificationPlan.requests(
            expiryDates: dates, tag: tag, now: Date(), calendar: cal)

        for req in requests {
            let content = UNMutableNotificationContent()
            content.title = "Stash"
            content.body = NSLocalizedString("Проверьте сроки документов", comment: "")
            var comps = DateComponents()
            comps.year = req.year; comps.month = req.month; comps.day = req.day; comps.hour = req.hour
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: req.identifier, content: content, trigger: trigger))
        }
    }
}
