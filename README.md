# Stash

[![CI](https://github.com/zeHattab/stash/actions/workflows/ci.yml/badge.svg)](https://github.com/zeHattab/stash/actions/workflows/ci.yml)

**Русский** · [English below](#english)

Stash — нативный менеджер паролей и личных документов для iPhone. Открытый код.

## Принципы

Эти правила действуют всегда и во всех частях проекта:

- **Нет сети.** Приложение не ходит в интернет. Никакой аналитики, крэш-репортеров,
  рекламы и трекинга. Единственные исключения в будущем — iCloud (CloudKit) и
  покупки (StoreKit), оба работают только в инфраструктуре Apple по желанию пользователя.
- **Нет трекинга.** `NSPrivacyTracking = false`, список доменов трекинга пуст,
  собираемых данных нет (см. `PrivacyInfo.xcprivacy`).
- **Шифрование на устройстве.** Все данные шифруются локально; в открытом виде
  ничего на диск не пишется. Используется только стандартная криптография Apple
  (CryptoKit / CommonCrypto), поэтому в `Info.plist` указано
  `ITSAppUsesNonExemptEncryption = NO`.
- **Ноль сторонних зависимостей.** Никаких SPM/CocoaPods. Только системные
  фреймворки: CryptoKit, CommonCrypto, LocalAuthentication, AuthenticationServices,
  VisionKit, Vision, StoreKit, UserNotifications.

## Требования

- Xcode 26 или новее (язык Swift 6, SDK iOS 26). С апреля 2026 App Store принимает
  только сборки из Xcode 26 / iOS 26 SDK.
- iOS 17.0+, только iPhone.

> На этом этапе (заход 1) в репозитории — только каркас: точки входа, пустой общий
> модуль, заглушка расширения AutoFill и проходящий юнит-тест. Бизнес-логики,
> моделей данных, экранов и криптографии ещё нет.

## Сборка

```bash
# Сборка приложения под симулятор
xcodebuild -scheme Stash \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Юнит-тесты общего модуля StashCore
xcodebuild -scheme StashCore \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Проект собирается командой `xcodebuild` без ручных действий в Xcode. Для запуска
на устройстве задайте свою команду разработчика (`DEVELOPMENT_TEAM`) и
App Group `group.com.portie24.stash` в своём аккаунте Apple Developer.

**Локально нужен Xcode 26+.** На более старом Xcode (например, Xcode 14 на macOS
Ventura) проект не собрать: не хватает компилятора Swift 6 и SDK iOS 17/26. Поэтому
вся сборка и тесты идут в [GitHub Actions](https://github.com/zeHattab/stash/actions/workflows/ci.yml)
на macOS-раннерах с Xcode 26 (см. `.github/workflows/ci.yml`). Публикация в
TestFlight — через `.github/workflows/testflight.yml` (запускается вручную).

## Структура

```
App/            Точка входа и корневой экран приложения
AutoFill/       Расширение AutoFill Credential Provider (заглушка)
StashCore/      Общий модуль: Crypto/, Storage/, Models/ (пока пусто)
StashCoreTests/ Юнит-тесты общего модуля
```

## Безопасность: как сообщить об уязвимости

Нашли проблему безопасности? Напишите на **hello@portie24.com**.
Пожалуйста, не создавайте публичный issue до того, как мы ответим.

## Лицензия

GNU General Public License v3.0 — см. [LICENSE](LICENSE).

---

<a name="english"></a>
## English

Stash is a native password and personal-document manager for iPhone. Open source.

### Principles

These rules hold everywhere in the project, always:

- **No network.** The app never talks to the internet. No analytics, crash
  reporters, ads, or tracking. The only future exceptions are iCloud (CloudKit)
  and purchases (StoreKit) — both inside Apple's own infrastructure, at the
  user's choice.
- **No tracking.** `NSPrivacyTracking = false`, no tracking domains, no collected
  data (see `PrivacyInfo.xcprivacy`).
- **On-device encryption.** All data is encrypted locally; nothing is ever written
  to disk in the clear. Only Apple's standard cryptography is used
  (CryptoKit / CommonCrypto), so `Info.plist` declares
  `ITSAppUsesNonExemptEncryption = NO`.
- **Zero third-party dependencies.** No SPM/CocoaPods. System frameworks only:
  CryptoKit, CommonCrypto, LocalAuthentication, AuthenticationServices, VisionKit,
  Vision, StoreKit, UserNotifications.

### Requirements

- Xcode 26 or newer (Swift 6 language mode, iOS 26 SDK). Since April 2026 the App
  Store only accepts builds made with Xcode 26 / the iOS 26 SDK.
- iOS 17.0+, iPhone only.

> At this stage (milestone 1) the repository contains only the scaffold: entry
> points, an empty shared module, an AutoFill extension stub, and one passing unit
> test. No business logic, data models, screens, or cryptography yet.

### Build

```bash
# Build the app for the simulator
xcodebuild -scheme Stash \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Unit tests for the shared StashCore module
xcodebuild -scheme StashCore \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

The project builds with plain `xcodebuild`, no manual steps in Xcode. To run on a
device, set your own `DEVELOPMENT_TEAM` and register the App Group
`group.com.portie24.stash` in your Apple Developer account.

**You need Xcode 26+ locally.** Older Xcode (e.g. Xcode 14 on macOS Ventura) cannot
build the project — it lacks the Swift 6 compiler and the iOS 17/26 SDK. All builds
and tests therefore run in [GitHub Actions](https://github.com/zeHattab/stash/actions/workflows/ci.yml)
on macOS runners with Xcode 26 (see `.github/workflows/ci.yml`). TestFlight releases
go through `.github/workflows/testflight.yml` (triggered manually).

### Layout

```
App/            App entry point and root screen
AutoFill/       AutoFill Credential Provider extension (stub)
StashCore/      Shared module: Crypto/, Storage/, Models/ (empty for now)
StashCoreTests/ Unit tests for the shared module
```

### Security: reporting a vulnerability

Found a security issue? Email **hello@portie24.com**.
Please don't open a public issue before we've had a chance to respond.

### License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
