#!/usr/bin/env python3
"""Контекстная проверка локализации.

Кириллический строковый литерал (вне комментариев, без интерполяции) ДОПУСТИМ только если
он реально идёт через локализацию:
  1) первым аргументом локализующего API: Text/Button/Label/Section/Toggle/Picker/TextField/
     SecureField/NavigationLink/Link/Stepper/Menu/DisclosureGroup/LabeledContent(…"…"),
     .navigationTitle/.alert/.confirmationDialog/.accessibilityLabel/.accessibilityHint/
     .help/.searchable(…"…");
  2) в обёртке String(localized:"…")/LocalizedStringResource("…")/LocalizedStringKey("…")/
     NSLocalizedString("…");
  3) как аргумент параметра типа LocalizedStringKey/LocalizedStringResource (метки таких
     параметров собираются из сигнатур автоматически);
  4) возвращается из функции/свойства с типом -> LocalizedStringKey / -> LocalizedStringResource.
Всё остальное (return "…", присваивания, тернарники, массивы, аргументы String-параметров)
— ОШИБКА, если не в ALLOWLIST с причиной. Наличие перевода в каталоге НЕ делает verbatim-
литерал допустимым (каталог при verbatim не читается).

Дополнительно: литерал в localizing-позиции обязан иметь en в каталоге своей области.

  python3 tools/check_strings.py   # exit 1 при нарушениях
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

APP_CATALOG = os.path.join(ROOT, "App", "Resources", "Localizable.xcstrings")
AUTOFILL_CATALOG = os.path.join(ROOT, "AutoFill", "Localizable.xcstrings")

# (область, каталог, globs). StashCore локализуется через Bundle.main → каталог App.
SCOPES = [
    ("App", APP_CATALOG, ["App/**/*.swift", "StashCore/**/*.swift", "AutoFill/AutoFillListView.swift"]),
    ("AutoFill", AUTOFILL_CATALOG, ["AutoFill/**/*.swift"]),
]

CYR = re.compile("[А-Яа-яЁё]")
STRING_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')

ALLOWLIST = {
    "init(coder:) не используется": "сообщение fatalError, не UI",
    ")» будет удалена без возможности восстановить.": "фрагмент интерполяции Text(«Запись «%@»…»)",
    "ё": "транслитерация поиска (VaultSearch), не UI",
    "Ё": "транслитерация поиска (VaultSearch), не UI",
    "е": "транслитерация поиска (VaultSearch), целевой символ",
}

# Вызовы, у которых первый аргумент локализуется (LocalizedStringKey).
BASE_CALLS = {"Text", "Button", "Label", "Section", "Toggle", "Picker", "TextField",
              "SecureField", "NavigationLink", "Link", "Stepper", "Menu", "DisclosureGroup",
              "LabeledContent", "ConfirmationDialog", "DatePicker", "GroupBox", "TabView",
              "LocalizedStringResource", "LocalizedStringKey", "NSLocalizedString"}
MODS = {"navigationTitle", "navigationBarTitle", "navigationSubtitle", "alert",
        "confirmationDialog", "accessibilityLabel", "accessibilityHint", "help", "searchable"}
LABEL_BEFORE = re.compile(r'(\w+)\s*:\s*$')
BASE_LABELS = {"localized", "placeholder", "prompt", "titleKey", "comment"}

SIG_RETURN = re.compile(r'->\s*([A-Za-z_][A-Za-z0-9_]*)')
SIG_VAR = re.compile(r'\bvar\s+\w+\s*:\s*([A-Za-z_][A-Za-z0-9_]*)\s*\{')
LOCALIZING_TYPES = {"LocalizedStringKey", "LocalizedStringResource"}
PARAM_TYPED = re.compile(r'(\w+)\s*:\s*(?:LocalizedStringKey|LocalizedStringResource)\b')
# func NAME(firstParam: LocalizedString*…) — первый аргумент локализуется.
FIRST_PARAM_FUNC = re.compile(
    r'func\s+(\w+)\s*\(\s*(?:_\s+)?\w+\s*:\s*(?:LocalizedStringKey|LocalizedStringResource)\b')
IDENT_BEFORE_PAREN = re.compile(r'(\.?)([A-Za-z_][A-Za-z0-9_]*)\s*$')


def code_part(line):
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


def has_en(catalog, key):
    e = catalog.get(key, {}).get("localizations", {}).get("en")
    if not e:
        return False
    if "stringUnit" in e:
        return bool(e["stringUnit"].get("value"))
    return "variations" in e


def collect_signatures():
    labels, calls = set(BASE_LABELS), set(BASE_CALLS)
    for path in glob.glob(os.path.join(ROOT, "App", "**", "*.swift"), recursive=True) + \
            glob.glob(os.path.join(ROOT, "AutoFill", "**", "*.swift"), recursive=True) + \
            glob.glob(os.path.join(ROOT, "StashCore", "**", "*.swift"), recursive=True):
        text = open(path, encoding="utf-8").read()
        for m in PARAM_TYPED.finditer(text):
            labels.add(m.group(1))
        for m in FIRST_PARAM_FUNC.finditer(text):
            calls.add(m.group(1))
    return labels, calls


def nearest_call(before):
    """Идентификатор перед ближайшей НЕзакрытой '(' слева от литерала (и был ли '.')."""
    depth = 0
    for i in range(len(before) - 1, -1, -1):
        c = before[i]
        if c == ")":
            depth += 1
        elif c == "(":
            if depth == 0:
                m = IDENT_BEFORE_PAREN.search(before[:i])
                return (m.group(1) == ".", m.group(2)) if m else (False, None)
            depth -= 1
    return (False, None)


def returns_localizing(lines, idx):
    """Ближайшая вверх сигнатура func/var: возвращает ли LocalizedStringKey/Resource."""
    for j in range(idx, -1, -1):
        code = code_part(lines[j])
        mv = SIG_VAR.search(code)
        if mv:
            return mv.group(1) in LOCALIZING_TYPES
        if "func " in code:
            mr = SIG_RETURN.search(code)
            if mr:
                return mr.group(1) in LOCALIZING_TYPES
            return False
    return False


def localizing_context(lines, idx, before, labels, calls):
    # 1) явная метка-параметр: localized:/placeholder:/title:/… где тип LocalizedString*
    mb = LABEL_BEFORE.search(before)
    if mb and mb.group(1) in labels:
        return True
    # 2) литерал (в т.ч. в тернарнике) внутри локализующего вызова: ближайшая открытая '('
    is_dot, ident = nearest_call(before)
    if ident and (ident in calls or (is_dot and ident in MODS)):
        return True
    # 2b) многострочный вызов: префикс пуст → смотрим конец прошлой строки
    if before.strip() == "" and idx > 0:
        is_dot2, ident2 = nearest_call(code_part(lines[idx - 1]).rstrip())
        if ident2 and (ident2 in calls or (is_dot2 and ident2 in MODS)):
            return True
    # 3) возврат из функции/свойства с типом LocalizedStringKey/Resource
    if returns_localizing(lines, idx):
        return True
    return False


def check_scope(name, catalog_path, globs, labels, calls):
    catalog = json.load(open(catalog_path, encoding="utf-8"))["strings"]
    files = []
    for g in globs:
        files += glob.glob(os.path.join(ROOT, g), recursive=True)
    bad_ctx, bad_tr = {}, {}
    for path in sorted(set(files)):
        lines = open(path, encoding="utf-8").read().splitlines()
        for ln, raw in enumerate(lines):
            code = code_part(raw)
            for m in STRING_LITERAL.finditer(code):
                s = m.group(1)
                if not CYR.search(s) or "\\(" in s or s in ALLOWLIST:
                    continue
                before = code[:m.start()]
                where = f"{os.path.basename(path)}:{ln+1}"
                if not localizing_context(lines, ln, before, labels, calls):
                    bad_ctx.setdefault(s, where)
                elif not has_en(catalog, s):
                    bad_tr.setdefault(s, where)
    if bad_ctx:
        print("[%s] кириллица НЕ через локализацию (verbatim) — %d:" % (name, len(bad_ctx)))
        for s in sorted(bad_ctx):
            print("  %-52r %s" % (s, bad_ctx[s]))
    if bad_tr:
        print("[%s] нет перевода en в каталоге — %d:" % (name, len(bad_tr)))
        for s in sorted(bad_tr):
            print("  %-52r %s" % (s, bad_tr[s]))
    return len(bad_ctx) + len(bad_tr)


def main():
    labels, calls = collect_signatures()
    total = 0
    for name, catalog, globs in SCOPES:
        total += check_scope(name, catalog, globs, labels, calls)
    if total:
        return 1
    print("OK: вся кириллица идёт через локализацию и переведена (App + AutoFill + StashCore).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
