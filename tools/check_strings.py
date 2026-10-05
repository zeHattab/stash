#!/usr/bin/env python3
"""Строгая проверка локализации: ЛЮБОЙ кириллический строковый литерал в .swift (вне
комментариев) обязан иметь en-перевод в каталоге своей области ИЛИ стоять в ALLOWLIST
с причиной. Иначе CI падает. Так ловится весь класс «протекающей» локализации — не только
Text("…"), но и аргументы функций, свойства, массивы, алерты, тосты, уведомления и т.п.

Отдельно (не валит сборку) печатает ПРЕДУПРЕЖДЕНИЕ про параметры-строки UI-текста
(title/text/placeholder/…: String), которые легко показать без локализации.

Области (каждый .swift — со СВОИМ каталогом; общий AutoFillListView.swift — в обеих):
  App/ + AutoFill/AutoFillListView.swift → App/Resources/Localizable.xcstrings
  AutoFill/                              → AutoFill/Localizable.xcstrings

  python3 tools/check_strings.py   # exit 1 при непереведённых/неразрешённых литералах
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SCOPES = [
    ("App", os.path.join(ROOT, "App", "Resources", "Localizable.xcstrings"),
     ["App/**/*.swift", "AutoFill/AutoFillListView.swift"]),
    ("AutoFill", os.path.join(ROOT, "AutoFill", "Localizable.xcstrings"),
     ["AutoFill/**/*.swift"]),
]

CYR = re.compile("[А-Яа-яЁё]")
STRING_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')

# Кириллические литералы, которым НЕ нужен перевод (с причиной).
ALLOWLIST = {
    "init(coder:) не используется": "сообщение fatalError, не UI",
    # Артефакт разбора: это хвост интерполированного Text("Запись «\\(...)» будет …"),
    # реальный ключ — формат «Запись «%@» будет удалена…» (переведён).
    ")» будет удалена без возможности восстановить.": "фрагмент интерполяции, не отдельный литерал",
}

# Параметры UI-текста, которые должны быть LocalizedStringKey/Resource, а не String.
# Исключаем String(...) / String<...> — это вызовы, а не объявления параметра.
PARAM_WARN = re.compile(r'\b(title|text|placeholder|message|subtitle|prompt|label|hint|caption)\s*:\s*String\b(?!\s*[(<.])')
# Эти String-параметры — заведомо динамический/уже-локализованный контент (не литералы).
PARAM_ALLOW = {
    ("Clipboard.swift", "text"),       # Toast: уже локализованная строка
    ("ItemRow.swift", "title"),        # имя записи пользователя
    ("ItemRow.swift", "subtitle"),     # произв. из данных
    ("NoteEditorView.swift", "title"), ("NoteEditorView.swift", "text"),
    ("LoginEditorView.swift", "title"), ("DocumentEditorView.swift", "title"),
    ("SecretTextField.swift", "text"),
    ("CredentialProviderViewController.swift", "text"),  # showMessage(_:) — String(localized:)
    ("CreatePasswordView.swift", "label"),               # computed, из String(localized:)
    ("AttachmentsView.swift", "hint"),                   # @State, задаётся через String(localized:)
}


def code_part(line):
    """Отрезает // комментарий, не задевая // внутри строк."""
    out, i, in_str = [], 0, False
    while i < len(line):
        c = line[i]
        if c == '"' and (i == 0 or line[i - 1] != "\\"):
            in_str = not in_str
        if not in_str and c == "/" and i + 1 < len(line) and line[i + 1] == "/":
            break
        out.append(c)
        i += 1
    return "".join(out)


def has_en(entry):
    loc = entry.get("localizations", {}).get("en")
    if not loc:
        return False
    if "stringUnit" in loc:
        return bool(loc["stringUnit"].get("value"))
    if "variations" in loc:
        return True
    return False


def check_scope(name, catalog_path, globs):
    with open(catalog_path, encoding="utf-8") as fh:
        strings = json.load(fh)["strings"]
    files = []
    for g in globs:
        files += glob.glob(os.path.join(ROOT, g), recursive=True)
    missing = {}
    for path in sorted(set(files)):
        with open(path, encoding="utf-8") as fh:
            for ln, line in enumerate(fh, 1):
                code = code_part(line)
                for m in STRING_LITERAL.finditer(code):
                    s = m.group(1)
                    if not CYR.search(s) or "\\(" in s:
                        continue  # не кириллица или интерполяция (формат-ключ)
                    if s in ALLOWLIST:
                        continue
                    if s not in strings or not has_en(strings[s]):
                        missing.setdefault(s, f"{os.path.basename(path)}:{ln}")
    if missing:
        print("[%s] нет перевода en / не в allowlist (%d):" % (name, len(missing)))
        for s in sorted(missing):
            print("  %-52r %s" % (s, missing[s]))
    return missing


def warn_params():
    hits = []
    for path in glob.glob(os.path.join(ROOT, "App", "**", "*.swift"), recursive=True) + \
            glob.glob(os.path.join(ROOT, "AutoFill", "**", "*.swift"), recursive=True):
        base = os.path.basename(path)
        with open(path, encoding="utf-8") as fh:
            for ln, line in enumerate(fh, 1):
                for m in PARAM_WARN.finditer(code_part(line)):
                    if (base, m.group(1)) in PARAM_ALLOW:
                        continue
                    hits.append(f"{base}:{ln}  {m.group(1)}: String")
    if hits:
        print("⚠️  параметры UI-текста типа String (используйте LocalizedStringKey/Resource):")
        for h in hits:
            print("   " + h)


def main():
    total = 0
    for name, catalog, globs in SCOPES:
        total += len(check_scope(name, catalog, globs))
    warn_params()
    if total:
        return 1
    print("OK: все кириллические литералы переведены (App + AutoFill).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
