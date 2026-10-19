#!/usr/bin/env python3
"""Scan SwiftUI literals into Localizable.xcstrings and machine-translate them.

SwiftUI's Text, Button and Label take a LocalizedStringKey, so a literal compiles into a
lookup key without touching the call sites. This script collects those literals, merges them
into the string catalog, and optionally asks a local Ollama model for Simplified Chinese.

Machine translations are written with state "needs-review", never "translated": a 3B model
happily turns "%1$@" into "%@@" and no review pass should trust that silently.

  scripts/translate_zh.py scan                 list keys, merge missing ones into the catalog
  scripts/translate_zh.py scan --dry-run       show what would be added
  scripts/translate_zh.py translate --limit 5  pilot a few keys through Ollama
  scripts/translate_zh.py translate            everything still untranslated
  scripts/translate_zh.py polish --dry-run     add the spaces between Chinese and Latin text

Rejected output (echoed back, or format specifiers changed) is reported in
~/Library/Caches/airstore-l10n/needs-attention.json and stays out of the catalog, so the next
run picks it up again. Re-running translate is how a batch retries itself.
"""


import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "SideStore", "Resources", "Localizable.xcstrings")
SOURCE_LANGS = ("SideStore", "AltStore", "Shared")

# SwiftUI APIs whose first string argument is a LocalizedStringKey, plus the in-project row
# helpers that forward their literals into Text.
LITERAL_PATTERNS = [
    re.compile(r'\bText\(\s*"((?:[^"\\]|\\.)+)"'),
    re.compile(r'\bButton\(\s*"((?:[^"\\]|\\.)+)"'),
    re.compile(r'\bLabel\(\s*"((?:[^"\\]|\\.)+)"'),
    re.compile(r'\.navigationTitle\(\s*"((?:[^"\\]|\\.)+)"'),
    re.compile(r'\.alert\(\s*"((?:[^"\\]|\\.)+)"'),
    re.compile(r'\.settingsSectionTitle\(\s*"((?:[^"\\]|\\.)+)"'),
    re.compile(r'title:\s*"((?:[^"\\]|\\.)+)"'),
    re.compile(r'subtitle:\s*"((?:[^"\\]|\\.)+)"'),
    re.compile(r'message:\s*"((?:[^"\\]|\\.)+)"'),
]

# Left alone on purpose: brand and protocol names that would read worse translated.
KEEP_AS_IS = re.compile(r"^(https?://|\(.*\)$)")
PLACEHOLDER = re.compile(r"%(\d+\$)?[@dlsfui]|\{[^{}]+\}")
# Text("Found \(n) apps") is looked up as "Found %@ apps", so an interpolated literal is not a
# catalog key in the shape the regex captured. Normalising those needs balanced-paren parsing, so
# they are skipped until a --interpolated pass handles them; translating the raw form would add a
# key nothing ever looks up.
INTERPOLATION = re.compile(r"\\\(")
THINK_BLOCK = re.compile(r"<think>.*?</think>", re.DOTALL)

CJK = "[\\u4e00-\\u9fff\\u3000-\\u303f\\uff01-\\uff5e]"
CJK_THEN_LATIN = re.compile(f"({CJK})([A-Za-z0-9])")
LATIN_THEN_CJK = re.compile(f"([A-Za-z0-9%)])([\\u4e00-\\u9fff])")

SYSTEM_PROMPT = (
    "You translate iOS app UI strings from English into Simplified Chinese.\n"
    "Rules:\n"
    "- Keep every format specifier exactly: %@, %d, %1$@, %{variable}. Same set, same order.\n"
    "- Keep these words untranslated: AirStore, SideStore, Apple ID, Anisette, ADI, IPA, "
    "WireGuard, EMProxy, Minimuxer, SideSign, Bonjour, JIT, UDID, App Group, provisioning.\n"
    "- Keep the capitalisation style of ALL-CAPS section headings in caps.\n"
    "- Translate every ordinary English word. Only keep the brand and protocol names above; "
    "never leave a phrase like 'Cache Management' or 'Cellular Refresh' in English, and never "
    "answer with the input unchanged.\n"
    "- Output only the translation, one line, no quotes, no explanation."
)


def literals_in_repo():
    found = {}
    for lang_dir in SOURCE_LANGS:
        for base, _, files in os.walk(os.path.join(ROOT, lang_dir)):
            for name in files:
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(base, name)
                if os.sep + "Tests" + os.sep in path:
                    continue
                text = open(path, encoding="utf-8").read()
                for pattern in LITERAL_PATTERNS:
                    for match in pattern.finditer(text):
                        literal = match.group(1)
                        if len(literal) < 3 or literal.startswith("$"):
                            continue
                        if KEEP_AS_IS.match(literal):
                            continue
                        if INTERPOLATION.search(literal):
                            continue
                        found.setdefault(literal.replace('\\"', '"'), []).append(
                            os.path.relpath(path, ROOT)
                        )
    return found


def load_catalog():
    with open(CATALOG, encoding="utf-8") as handle:
        return json.load(handle)


def save_catalog(catalog):
    with open(CATALOG, "w", encoding="utf-8") as handle:
        json.dump(catalog, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


def untranslated_keys(catalog, literals):
    entries = catalog["strings"]
    keys = []
    for literal in sorted(literals):
        entry = entries.get(literal)
        if entry is None:
            keys.append(literal)
            continue
        localizations = entry.get("localizations", {})
        if "zh-Hans" not in localizations:
            keys.append(literal)
    return keys


def ollama_generate(model, string, host):
    prompt = f"{SYSTEM_PROMPT}\n\nEnglish: {string}\nSimplified Chinese:"
    body = json.dumps({
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": {"temperature": 0.1, "num_ctx": 2048, "keep_alive": "2m"},
    }).encode()
    request = urllib.request.Request(
        f"{host}/api/generate", data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        raw = json.loads(response.read()).get("response", "")
    # A reasoning model can still emit its scratch pad; only the last meaningful line is the string.
    cleaned = THINK_BLOCK.sub("", raw).strip().splitlines()
    return cleaned[-1].strip().strip('"') if cleaned else ""


def placeholder_check(source, translated):
    """Reject a translation whose specifiers changed; that is the failure that breaks a screen."""
    return sorted(PLACEHOLDER.findall(source) and [m.group(0) for m in PLACEHOLDER.finditer(source)]) == \
        sorted(m.group(0) for m in PLACEHOLDER.finditer(translated))


def cmd_scan(args):
    literals = literals_in_repo()
    catalog = load_catalog()
    missing = untranslated_keys(catalog, literals)
    print(f"literals found in code: {len(literals)}")
    print(f"keys in catalog:        {len(catalog['strings'])}")
    print(f"still untranslated:     {len(missing)}")
    for key in missing[: args.show]:
        print(f"  - {key!r} ({', '.join(sorted(set(literals[key]))[:2])})")

    if args.dry_run or not missing:
        return

    for key in missing:
        catalog["strings"][key] = {"extractionState": "manual"}
    save_catalog(catalog)
    print(f"added {len(missing)} keys to {os.path.relpath(CATALOG, ROOT)} (no translation yet)")


def cmd_translate(args):
    literals = literals_in_repo()
    catalog = load_catalog()
    missing = untranslated_keys(catalog, literals)
    todo = missing[: args.limit] if args.limit else missing
    print(f"{len(todo)} of {len(missing)} untranslated keys to process")

    host = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434").replace("tcp://", "http://")
    failures = []
    for index, key in enumerate(todo, 1):
        translated = ""
        try:
            translated = ollama_generate(args.model, key, host)
        except Exception as error:
            failures.append((key, f"request failed: {error}"))
            print(f"[{index}/{len(todo)}] FAIL {key!r}: {error}")
            continue

        if not translated:
            failures.append((key, "empty response"))
            continue
        if translated == key:
            # A small model answers by echoing when it does not know what to do with the string.
            # Recording it as untranslated keeps it in the next batch instead of hiding it.
            failures.append((key, "echoed back unchanged"))
            print(f"[{index}/{len(todo)}] SKIP {key!r}: echoed back unchanged")
            continue
        if not placeholder_check(key, translated):
            failures.append((key, f"placeholder mismatch: {translated!r}"))
            print(f"[{index}/{len(todo)}] SKIP {key!r}: placeholder mismatch")
            continue

        catalog["strings"][key] = {
            "extractionState": "manual",
            "localizations": {
                "zh-Hans": {"stringUnit": {"state": "needs-review", "value": translated}}
            },
        }
        print(f"[{index}/{len(todo)}] {key!r} -> {translated!r}")

        if index % args.checkpoint == 0:
            save_catalog(catalog)

    save_catalog(catalog)
    if failures:
        report_dir = os.path.expanduser("~/Library/Caches/airstore-l10n")
        os.makedirs(report_dir, exist_ok=True)
        report = os.path.join(report_dir, "needs-attention.json")
        with open(report, "w", encoding="utf-8") as handle:
            json.dump(failures, handle, ensure_ascii=False, indent=2)
        print(f"{len(failures)} rejected, written to {report}")


def cmd_polish(args):
    """Space between Chinese and Latin or digits, the way Apple writes its own zh-Hans UI.

    Deterministic and reversible per string, so it belongs in a script rather than in a prompt:
    a model asked to add these spaces starts dropping format specifiers instead.
    """
    catalog = load_catalog()
    changed = 0
    for key, entry in catalog["strings"].items():
        unit = entry.get("localizations", {}).get("zh-Hans", {}).get("stringUnit", {})
        value = unit.get("value")
        if not value:
            continue
        spaced = CJK_THEN_LATIN.sub(r"\1 \2", value)
        spaced = LATIN_THEN_CJK.sub(r"\1 \2", spaced)
        spaced = re.sub(r"\s{2,}", " ", spaced).strip()
        if spaced != value:
            changed += 1
            print(f"  {value!r} -> {spaced!r}")
            if not args.dry_run:
                unit["value"] = spaced

    print(f"{changed} values restyled" + (" (dry run, nothing written)" if args.dry_run else ""))
    if changed and not args.dry_run:
        save_catalog(catalog)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    scan = sub.add_parser("scan")
    scan.add_argument("--dry-run", action="store_true")
    scan.add_argument("--show", type=int, default=40)

    translate = sub.add_parser("translate")
    translate.add_argument("--model", default=os.environ.get("ML_MODEL", "deepseek-r1:8b"))
    translate.add_argument("--limit", type=int, default=0)
    translate.add_argument("--checkpoint", type=int, default=20)

    polish = sub.add_parser("polish")
    polish.add_argument("--dry-run", action="store_true")

    args = parser.parse_args()
    if args.command == "scan":
        cmd_scan(args)
    elif args.command == "translate":
        cmd_translate(args)
    else:
        cmd_polish(args)


if __name__ == "__main__":
    main()
