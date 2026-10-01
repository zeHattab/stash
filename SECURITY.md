# Безопасность Stash

**Русский** · [English below](#english)

Это описание модели безопасности крипто-ядра Stash простым языком — часть доверия
к открытому коду. Если нашли уязвимость, пишите на **hello@portie24.com** и, пожалуйста,
не создавайте публичный issue до нашего ответа.

## Что и как шифруется

**Иерархия ключей.**
1. Из мастер-пароля функцией **PBKDF2-HMAC-SHA256** выводится ключ **KEK**
   (key-encryption key). Соль — 16 случайных байт, итераций по умолчанию **600 000**.
2. При создании сейфа генерируется случайный **Vault Key (VK)** — 256 бит.
   VK шифрует сами данные.
3. VK хранится только в «обёрнутом» виде: зашифрован ключом KEK через
   **AES-256-GCM**. На диск VK в открытом виде не попадает никогда.
4. Данные (список записей) шифруются **AES-256-GCM** ключом VK. На каждую запись
   файла генерируется **новый случайный nonce**.

**Зачем две ступени.** Смена мастер-пароля меняет только обёртку VK — сам VK
остаётся прежним. Это позволяет менять пароль, не перешифровывая ключ данных.

**Заголовок как подпись.** Версия формата, параметры KDF и обёрнутый VK образуют
заголовок, который целиком передаётся как *authenticated data* при шифровании
данных. Любая подмена заголовка ломает расшифровку — значит, его нельзя
незаметно изменить.

## Формат файла (`vault.stash`)

```
{
  "format": "stash-vault",
  "header": <base64 — точные байты заголовка (служат AAD)>,
  "ciphertext": <base64 — AES-256-GCM: nonce‖ciphertext‖tag>
}
```
Заголовок (внутри `header`):
```
{
  "formatVersion": 1,
  "kdf": { "algorithm": "pbkdf2-hmac-sha256", "iterations": 600000, "salt": <base64> },
  "wrappedVaultKey": <base64 — VK под KEK (AES-GCM)>
}
```
Параметры KDF лежат в заголовке специально: позже можно перейти на другой KDF
(например, Argon2), не теряя старые сейфы.

## Face ID / Touch ID (через Keychain)

Биометрия НЕ хранит отдельную копию VK в файле. Когда пользователь включает Face ID,
VK кладётся в **Keychain**:
- класс `kSecClassGenericPassword`, значение — байты VK;
- `SecAccessControl` с флагом `.biometryCurrentSet` — доступ только по текущему
  набору биометрии (добавили/сменили лицо или палец — запись аннулируется);
- доступность `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` — требует код-пароль,
  не покидает устройство;
- `kSecAttrSynchronizable = false` — не уходит в iCloud;
- группа доступа общая с расширением AutoFill (Keychain Sharing).

Разблокировка по Face ID = чтение VK из Keychain (с биометрическим запросом) и
`unlock(vaultKey:)`. Если набор биометрии изменился или запись пропала — она тихо
удаляется, приложение просит мастер-пароль и после входа снова предлагает включить
Face ID. Прежнее поле `wrappedVaultKeyBiometric` из формата файла удалено.

## Различение ошибок

- **wrongPassword** — не удалось развернуть VK (неверный мастер-пароль).
- **corrupted** — данные не прошли проверку подлинности (повреждены/подменены).
- **unsupportedVersion** — версия формата новее, чем понимает эта сборка.
- **ioError** — сбой ввода-вывода или системного примитива.

Неверный пароль и порча файла — разные ошибки.

## Что защищено

- Содержимое сейфа на диске зашифровано; без мастер-пароля его не прочитать.
- Файл пишется атомарно (временный файл → замена) и помечается
  `FileProtectionType.complete` — на устройстве он недоступен, пока оно заблокировано.
- Подмена заголовка или шифротекста приводит к ошибке, а не к тихой выдаче неверных данных.

## Чего защита НЕ покрывает (честно)

- **Пока приложение разблокировано, расшифрованные данные лежат в памяти.**
  `lock()` отпускает ключ (CryptoKit обнуляет его при освобождении) и сбрасывает
  кеш, но строки (`String`) в Swift нельзя гарантированно затереть — они живут
  в памяти до переиспользования.
- **Мастер-пароль нельзя восстановить.** Нет «забыли пароль». Забыли — данные
  потеряны безвозвратно. Это цена отсутствия доступа у кого-либо, кроме вас.
- Защита не спасает от скомпрометированного устройства (вредонос, jailbreak,
  перехват ввода) — там, где злоумышленник видит ввод пароля или память процесса.
- `FileProtectionType.complete` действует на устройстве; в симуляторе (CI) не применяется.
- Сила защиты зависит от стойкости мастер-пароля: PBKDF2 замедляет перебор, но
  слабый пароль остаётся слабым.

---

<a name="english"></a>
# Security of Stash

This is a plain-language description of the security model of Stash's crypto core —
part of trusting open-source software. Found a vulnerability? Email
**hello@portie24.com** and please don't open a public issue before we respond.

## What is encrypted, and how

**Key hierarchy.**
1. A **KEK** (key-encryption key) is derived from the master password with
   **PBKDF2-HMAC-SHA256**. Salt is 16 random bytes; the default is **600,000** iterations.
2. On vault creation a random 256-bit **Vault Key (VK)** is generated; it encrypts
   the actual data.
3. VK is stored only *wrapped* — encrypted with the KEK via **AES-256-GCM**. VK is
   never written to disk in the clear.
4. The data (the list of items) is encrypted with **AES-256-GCM** under VK, with a
   **fresh random nonce** on every file write.

**Why two steps.** Changing the master password only re-wraps the VK — the VK itself
stays the same, so the data key never has to rotate.

**Header as a signature.** The format version, KDF parameters and wrapped VK form a
header that is passed in full as *authenticated data* when the payload is encrypted.
Tampering with the header breaks decryption, so it cannot be altered unnoticed.

## File format (`vault.stash`)

```
{
  "format": "stash-vault",
  "header": <base64 — the exact header bytes (used as AAD)>,
  "ciphertext": <base64 — AES-256-GCM: nonce‖ciphertext‖tag>
}
```
Header (inside `header`):
```
{
  "formatVersion": 1,
  "kdf": { "algorithm": "pbkdf2-hmac-sha256", "iterations": 600000, "salt": <base64> },
  "wrappedVaultKey": <base64 — VK under KEK (AES-GCM)>
}
```
KDF parameters live in the header on purpose: we can later switch to another KDF
(e.g. Argon2) without losing existing vaults.

## Face ID / Touch ID (via Keychain)

Biometrics do NOT keep a second copy of the VK in the file. When the user enables
Face ID, the VK is stored in the **Keychain**:
- class `kSecClassGenericPassword`, value is the VK bytes;
- `SecAccessControl` with `.biometryCurrentSet` — usable only with the current
  biometric set (enroll/replace a face or finger and the item is invalidated);
- accessibility `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` — requires a
  passcode and never leaves the device;
- `kSecAttrSynchronizable = false` — never goes to iCloud;
- access group shared with the AutoFill extension (Keychain Sharing).

Biometric unlock = reading the VK from the Keychain (with a biometric prompt) and
`unlock(vaultKey:)`. If the biometric set changed or the item is gone, it is silently
deleted, the app asks for the master password, and offers to re-enable Face ID after
sign-in. The former `wrappedVaultKeyBiometric` header field has been removed.

## Distinct errors

- **wrongPassword** — the VK could not be unwrapped (wrong master password).
- **corrupted** — the data failed authentication (damaged or tampered).
- **unsupportedVersion** — the format is newer than this build understands.
- **ioError** — an I/O or system-primitive failure.

A wrong password and a corrupted file are reported differently.

## What is protected

- The vault contents on disk are encrypted; unreadable without the master password.
- The file is written atomically (temp file → replace) and marked
  `FileProtectionType.complete` — on device it is unavailable while the device is locked.
- Tampering with the header or ciphertext yields an error, never silently wrong data.

## What is NOT protected (honestly)

- **While the app is unlocked, decrypted data lives in memory.** `lock()` releases
  the key (CryptoKit zeroes it on deallocation) and clears the cache, but Swift
  `String`s cannot be reliably wiped — they linger in memory until reused.
- **The master password cannot be recovered.** There is no "forgot password".
  Forget it and the data is gone for good — the price of no one but you having access.
- It does not defend a compromised device (malware, jailbreak, input capture) where
  an attacker can observe the password entry or process memory.
- `FileProtectionType.complete` applies on device; in the Simulator (CI) it is not enforced.
- Strength depends on the master password: PBKDF2 slows brute force, but a weak
  password stays weak.
