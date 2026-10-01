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

## Второй пароль (ложный сейф)

Функция «Второй пароль» даёт правдоподобное отрицание: мастер-пароль открывает
настоящий сейф, а отдельный второй пароль — ложный сейф с безобидными записями.

**Формат v3 (почему в слоте нет открытых полей).** Файл — контейнер из РОВНО ДВУХ
слотов одинакового размера, у всех пользователей, включена функция или нет. Внешний
заголовок (общий для обоих слотов) содержит только магию/версию/параметры KDF/размер
слота. Внутри слота — НИ ОДНОГО открытого поля:
`соль(16) ‖ wrapMaster(60) ‖ wrapRecovery(60) ‖ шифротекст(до конца слота)`.
Длина полезной нагрузки хранится ВНУТРИ шифртекста (len-префикс перед JSON, затем
случайный паддинг), поэтому шифртекст ровно заполняет слот и открытого поля длины
нет. В v2 было открытое 4-байтовое поле длины `L`: в занятом слоте — правдоподобное
число, в пустом (случайном) — почти всегда больше размера слота, что выдавало
занятость. В v3 этого поля нет; обе обёртки VK — выводы AES-GCM (nonce/ct/tag),
неотличимые от случайных байтов, как и неиспользуемый слот (сплошь случайные байты).
Настоящий сейф при создании/миграции кладётся в случайный слот. Любой введённый
пароль проверяется против обоих слотов и обеих обёрток (KDF по обеим солям
выполняется всегда); время ответа не зависит от того, какой слот подошёл. Признак
«ложный» лежит только внутри зашифрованного payload ложного сейфа.

**Ключ восстановления.** В каждом слоте VK обёрнут ДВАЖДЫ — мастер-паролем
(`wrapMaster`) и ключом восстановления (`wrapRecovery`). Обе обёртки — одинаковые
60-байтовые выводы AES-GCM и неотличимы от случайных данных, поэтому наличие ключа
восстановления НЕ выдаёт занятость слота. У каждого сейфа (в т.ч. ложного) свой ключ
восстановления; ключ одного сейфа никогда не открывает другой.

**Вложения (на будущее, требование).** Сканы/файлы документов НЕЛЬЗЯ хранить
отдельными файлами вне слотов: их наличие и размер выдавали бы занятость слота и
ломали бы правдоподобное отрицание. Вложения должны лежать внутри шифруемой
полезной нагрузки слота.

**От чего защищает.** От давления «разблокируй и покажи»: вы вводите второй пароль,
показывается ложный сейф, настоящий не раскрывается. От анализа файлов: по байтам
на диске нельзя доказать, что второй (настоящий) сейф существует — второй слот
выглядит как случайные данные.

**От чего НЕ защищает.** От знающего атакующего, который в курсе функции и требует
«второй пароль». От слежки за вводом (камера, плечо, кейлоггер). От взломанного
устройства (вредонос, доступ к памяти разблокированного приложения). При включённой
функции Face ID сам по себе сейф не открывает — всегда нужен пароль.

**Почему ложный сейф нужно наполнить.** Пустой или явно фальшивый ложный сейф не
убедителен. Готовых одинаковых для всех примеров НЕТ (в открытом коде они мгновенно
выдавали бы ложный сейф) — при включении открывается экран наполнения с кнопками по
типам записей; значения вы придумываете сами. Напоминание «ложный сейф почти пуст»
показывается ТОЛЬКО в настоящем сейфе и опирается на флаг в его payload (сколько
записей было при создании), поэтому не требует расшифровки ложного сейфа.

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

## Second password (decoy vault)

The "second password" feature provides plausible deniability: the master password
opens the real vault, while a separate second password opens a decoy vault with
harmless entries.

**Format v3 (why a slot has no cleartext fields).** The file is a container of
EXACTLY TWO equal-size slots, for every user, feature on or off. The outer header
(shared by both slots) holds only magic/version/KDF params/slot size. A slot has NO
cleartext field: `salt(16) ‖ wrapMaster(60) ‖ wrapRecovery(60) ‖ ciphertext(to end
of slot)`. The payload length is stored INSIDE the ciphertext (a length prefix before
the JSON, then random padding), so the ciphertext fills the slot exactly and there is
no cleartext length field. v2 had a cleartext 4-byte length `L`: in an occupied slot
a plausible number, in an empty (random) slot almost always larger than the slot —
which revealed occupancy. v3 removes it; both VK wrappings are AES-GCM outputs
(nonce/ct/tag), indistinguishable from random, like the unused slot (all random). The
real vault is placed in a random slot at creation/migration. Any entered password is
checked against both slots and both wrappings (the KDF runs over both salts); response
time does not depend on which slot matched. The "decoy" marker lives only inside the
decoy's encrypted payload.

**Recovery key.** In every slot the VK is wrapped TWICE — by the master password
(`wrapMaster`) and by a recovery key (`wrapRecovery`). Both are identical 60-byte
AES-GCM outputs, indistinguishable from random, so the presence of a recovery key
does not reveal slot occupancy. Each vault (including the decoy) has its own recovery
key; one vault's key never opens the other.

**Attachments (future requirement).** Document scans/files must NOT be stored as
separate files outside the slots: their presence and size would reveal slot occupancy
and break deniability. Attachments must live inside a slot's encrypted payload.

**What it protects against.** Coercion to "unlock and show": you enter the second
password, the decoy opens, the real vault is not revealed. File analysis: the bytes
on disk cannot prove a second (real) vault exists — the other slot looks like random
data.

**What it does NOT protect against.** A knowledgeable attacker aware of the feature
who demands the "second password". Input surveillance (camera, shoulder, keylogger).
A compromised device (malware, memory of the unlocked app). With the feature on, Face
ID alone never opens the vault — a password is always required.

**Why the decoy must be filled.** An empty or obviously fake decoy is unconvincing.
There are NO shared built-in sample entries (in open source they would instantly give
the decoy away) — enabling the feature opens a fill screen with buttons per entry type;
you invent the values yourself. The "decoy is almost empty" reminder appears ONLY in
the real vault and relies on a flag in its own payload (how many entries existed at
creation), so it needs no decryption of the decoy.
