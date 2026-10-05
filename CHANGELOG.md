# Changelog

All notable changes to Stash are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions use the app's marketing version.

## [1.0.1] — unreleased

### Fixed
- Parts of the interface (onboarding, password fields) stayed in Russian when the device
  language is English — text passed through `String`-typed helpers was shown verbatim.
  UI-text helpers now take `LocalizedStringKey`/`LocalizedStringResource`.

### Changed
- Removed the unused `LoginListController` from the AutoFill extension (its screen was
  replaced by `AutoFillListView` in 1.0.0).
- `tools/check_strings.py` now also checks the AutoFill extension's string catalog, not
  just the app's.

## [1.0.0] — 2026-10-04

First public release.

### Added
- Passwords and logins with a strong password generator and password history.
- Two-factor codes (TOTP, RFC 6238): add by QR scan, screenshot, or manual secret; live
  code with countdown; bulk import from Google Authenticator exports.
- AutoFill extension for Safari and apps — passwords and one-time codes; an in-extension
  "generate new password" action.
- Keyboard suggestions via the system credential-identity store (domain + login only,
  never passwords); automatically disabled when a second password is set.
- Documents (passports, IDs, insurance, and more) with an on-device scanner: VisionKit
  capture, Vision OCR, and an MRZ parser (TD1/TD2/TD3, ICAO 9303) with live camera reading.
- Document expiry reminders as local notifications with neutral text.
- Search, favorites, and a documents/2FA filter on the home screen.

### Security
- On-device encryption with Apple CryptoKit (AES-256-GCM) and CommonCrypto (PBKDF2).
- No network calls, no analytics, no tracking.
- Recovery key for a forgotten master password.
- Second password opening a separate decoy vault (duress protection); plausible-deniability
  container format v4.
- Third-party keyboards blocked for secret entry.

[1.0.0]: https://github.com/zeHattab/stash/releases/tag/v1.0.0
