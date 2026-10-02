#!/usr/bin/env python3
"""Проверяет англоязычную локализацию каталога строк App/Resources/Localizable.xcstrings.

Каталог ведём вручную (ключ = исходная ru-строка; добавляем localizations.en).
Скрипт находит русские пользовательские литералы в App/**/*.swift и сообщает,
для каких НЕТ перевода en. Строки с интерполяцией (\\( )) пропускаются — у них
в каталоге формат-ключи (%@/%lld), которые Xcode извлекает при сборке.

  python3 tools/check_strings.py           # отчёт; exit 1 если есть непереведённые
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "App", "Resources", "Localizable.xcstrings")

UI_PATTERNS = [
    r'Text\(\s*"((?:[^"\\]|\\.)*)"',
    r'Label\(\s*"((?:[^"\\]|\\.)*)"',
    r'Button\(\s*"((?:[^"\\]|\\.)*)"',
    r'Section\(\s*"((?:[^"\\]|\\.)*)"',
    r'Picker\(\s*"((?:[^"\\]|\\.)*)"',
    r'Toggle\(\s*"((?:[^"\\]|\\.)*)"',
    r'TextField\(\s*"((?:[^"\\]|\\.)*)"',
    r'navigationTitle\(\s*"((?:[^"\\]|\\.)*)"',
    r'\.alert\(\s*"((?:[^"\\]|\\.)*)"',
    r'LabeledContent\(\s*"((?:[^"\\]|\\.)*)"',
    r'DisclosureGroup\(\s*"((?:[^"\\]|\\.)*)"',
    r'accessibilityLabel\(\s*"((?:[^"\\]|\\.)*)"',
    r'placeholder:\s*"((?:[^"\\]|\\.)*)"',
    r'NSLocalizedString\(\s*"((?:[^"\\]|\\.)*)"',
    r'String\(localized:\s*"((?:[^"\\]|\\.)*)"',
    r'return\s+"((?:[^"\\]|\\.)*)"',
]
CYR = re.compile("[А-Яа-яЁё]")


def has_en(entry):
    loc = entry.get("localizations", {}).get("en")
    if not loc:
        return False
    if "stringUnit" in loc:
        return bool(loc["stringUnit"].get("value"))
    if "variations" in loc:
        return True  # множественные формы считаем переведёнными
    return False


def main():
    with open(CATALOG, encoding="utf-8") as fh:
        catalog = json.load(fh)
    strings = catalog["strings"]

    missing = {}
    for path in glob.glob(os.path.join(ROOT, "App", "**", "*.swift"), recursive=True):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line.strip().startswith("//"):
                    continue
                for pat in UI_PATTERNS:
                    for m in re.finditer(pat, line):
                        s = m.group(1)
                        if not CYR.search(s) or "\\(" in s:
                            continue
                        if s not in strings or not has_en(strings[s]):
                            missing.setdefault(s, os.path.basename(path))

    if missing:
        print("Нет перевода en для %d строк:" % len(missing))
        for s in sorted(missing):
            print("  %-50r %s" % (s, missing[s]))
        return 1
    print("OK: все русские UI-строки имеют перевод en.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
