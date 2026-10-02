#!/usr/bin/env python3
"""Проверяет целостность Stash.xcodeproj/project.pbxproj (правим его вручную).

- синтаксис pbxproj (через plutil);
- нет повторных определений объектов (одинаковый 24-симв. ID слева от `= {isa`);
- каждый .swift на диске в App/StashCore/StashCoreTests/AutoFill ПРИСУТСТВУЕТ
  как PBXFileReference (иначе файл не попадёт в сборку — именно так когда-то
  потерялась часть кода).

Запуск: python3 tools/check_project.py   ( exit 1 при проблемах).
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBX = os.path.join(ROOT, "Stash.xcodeproj", "project.pbxproj")
SOURCE_DIRS = ["App", "StashCore", "StashCoreTests", "AutoFill"]
# Файлы, которые намеренно не входят в таргеты (нет таких сейчас).
IGNORE = set()


def fail(msg):
    print("FAIL:", msg)
    return False


def check_plist():
    r = subprocess.run(["plutil", "-convert", "xml1", "-o", os.devnull, PBX],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return fail("plutil: " + r.stderr.strip())
    return True


def check_duplicates(text):
    ids = re.findall(r'^\s*([0-9A-F]{24}) = \{isa', text, re.M)
    seen, dups = set(), set()
    for i in ids:
        (dups if i in seen else seen).add(i)
    if dups:
        return fail("повторные определения ID: " + ", ".join(sorted(dups)))
    return True


def check_all_sources_referenced(text):
    ok = True
    referenced = set(re.findall(r'path = ([^;]+\.swift)', text))
    referenced |= set(re.findall(r'path = "([^"]+\.swift)"', text))
    # в pbxproj пути хранятся как basename или подпуть (Documents/Foo.swift) — сравниваем по basename
    ref_basenames = {os.path.basename(p.strip()) for p in referenced}
    for d in SOURCE_DIRS:
        base = os.path.join(ROOT, d)
        for dirpath, _, files in os.walk(base):
            for f in files:
                if not f.endswith(".swift") or f in IGNORE:
                    continue
                if f not in ref_basenames:
                    rel = os.path.relpath(os.path.join(dirpath, f), ROOT)
                    ok = fail(f"{rel} не зарегистрирован в project.pbxproj")
    return ok


def main():
    with open(PBX, encoding="utf-8") as fh:
        text = fh.read()
    ok = all([check_plist(), check_duplicates(text), check_all_sources_referenced(text)])
    if ok:
        print("OK: project.pbxproj целостен, все .swift зарегистрированы.")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
