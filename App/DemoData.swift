import Foundation
import StashCore

/// Вымышленные данные для скриншотов App Store (launch-аргумент STASH_DEMO).
/// Ни одного реального имени/номера — всё очевидно придуманное.
enum DemoData {
    static func items(now: Date = Date()) -> [VaultItem] {
        let soon = now.addingTimeInterval(32 * 86_400)   // попадёт в «Скоро истекают»
        let later = now.addingTimeInterval(540 * 86_400)
        return [
            VaultItem(
                kind: .login(username: "alex.rivera", password: "T7h$Qw9!mK2p",
                             urls: ["github.com"],
                             totpSecret: "otpauth://totp/GitHub:alex.rivera?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&digits=6&period=30"),
                title: "GitHub", favorite: true),
            VaultItem(
                kind: .login(username: "alex@example.com", password: "b9@Lp3Wq_z8R",
                             urls: ["mail.example.com"], totpSecret: nil),
                title: "Example Mail"),
            VaultItem(
                kind: .login(username: "a.rivera", password: "Zx4!vN7#tQ1s",
                             urls: ["shop.example.net"], totpSecret: nil),
                title: "Demo Shop"),
            VaultItem(
                kind: .document(type: .foreignPassport,
                                fields: [
                                    DocumentFieldKey.number.rawValue: "AA0000000",
                                    DocumentFieldKey.fullName.rawValue: "ALEX RIVERA",
                                    DocumentFieldKey.birthDate.rawValue: "1990-05-14",
                                    DocumentFieldKey.country.rawValue: "UTO",
                                ],
                                expiresAt: soon, attachmentIDs: []),
                title: "Passport"),
            VaultItem(
                kind: .document(type: .driverLicense,
                                fields: [
                                    DocumentFieldKey.number.rawValue: "D1234567",
                                    DocumentFieldKey.fullName.rawValue: "ALEX RIVERA",
                                ],
                                expiresAt: later, attachmentIDs: []),
                title: "Driver’s License"),
            VaultItem(kind: .secureNote, title: "Wi-Fi at home",
                      notes: "Network: Rivera-Home\nPassword: purple-otter-42"),
        ]
    }
}
