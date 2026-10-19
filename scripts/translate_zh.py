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
import html
import json
import os
import re
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "SideStore", "Resources", "Localizable.xcstrings")
INFOPLIST_CATALOG = os.path.join(ROOT, "SideStore", "Resources", "InfoPlist.xcstrings")
SOURCE_LANGS = ("SideStore", "AltStore", "Shared")

# SwiftUI APIs whose first string argument is a LocalizedStringKey, plus the in-project row
# helpers that forward their literals into Text, plus the explicit NSLocalizedString calls the
# UIKit screens use. Missing that last group once made this report claim the UIKit surface was
# three strings when it is several hundred.
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
    re.compile(r'\bNSLocalizedString\(\s*"((?:[^"\\]|\\.)+)"'),
]

# Left alone on purpose: brand and protocol names that would read worse translated.
KEEP_AS_IS = re.compile(r"^(https?://|\(.*\)$)")
PLACEHOLDER = re.compile(r"%(\d+\$)?[@dlsfui]|\{[^{}]+\}")
# Text("Found \(n) apps") is looked up as "Found %@ apps", so an interpolated literal is not a
# catalog key in the shape the regex captured. Normalising those needs balanced-paren parsing, so
# they are skipped until a --interpolated pass handles them; translating the raw form would add a
# key nothing ever looks up.
INTERPOLATION = re.compile(r"\\\(")
SWIFT_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "'": "'", "\\": "\\"}


def swift_key(literal):
    """Turn a code literal into the string the runtime actually looks up.

    Text("a\\nb") is looked up with a real newline, so a catalog key holding the two characters
    backslash-n matches nothing and becomes a permanent dead entry.
    """
    return re.sub(r"\\(.)", lambda m: SWIFT_ESCAPES.get(m.group(1), m.group(0)), literal)
THINK_BLOCK = re.compile(r"<think>.*?</think>", re.DOTALL)

# These reach the screen as plain Swift strings, so the catalog cannot translate them until each
# call site is wrapped in NSLocalizedString. Listed separately from the SwiftUI literals so a
# coverage number does not hide them.
UIKIT_PATTERNS = [
    re.compile(r'\btext\s*=\s*"((?:[^"\\]|\\.)+)"'),
    re.compile(r'\bsetTitle\(\s*"((?:[^"\\]|\\.)+)"'),
    re.compile(r'\bplaceholder\s*=\s*"((?:[^"\\]|\\.)+)"'),
]
STORYBOARD_TITLE = re.compile(r'title="([^"]+)"')
# A storyboard row shows its UILabel, not its title attribute: the Settings rows are all text=.
STORYBOARD_LABEL = re.compile(r'text="([^"]+)"')

# A space goes between a Han character and Latin/digits. Matching on Han only: the wider CJK class
# included fullwidth punctuation, so "隧道（utun）" came back as "隧道（ utun）".
CJK_THEN_LATIN = re.compile("([\\u4e00-\\u9fff])([A-Za-z0-9])")
LATIN_THEN_CJK = re.compile("([A-Za-z0-9%)])([\\u4e00-\\u9fff])")

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
                        found.setdefault(swift_key(literal), []).append(
                            os.path.relpath(path, ROOT)
                        )
    return found


def load_catalog():
    with open(CATALOG, encoding="utf-8") as handle:
        return json.load(handle)


def load_infoplist_catalog():
    if not os.path.exists(INFOPLIST_CATALOG):
        return {}
    with open(INFOPLIST_CATALOG, encoding="utf-8") as handle:
        raw = json.load(handle).get("strings", {})
    return {
        key: {
            lang: entry.get("localizations", {}).get(lang, {}).get("stringUnit", {}).get("value", "")
            for lang in ("en", "zh-Hans")
        }
        for key, entry in raw.items()
    }


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
        if translated.lower() == key.lower():
            # Covers both the plain echo and the worse variant where the model only lowercased the
            # term: 'Provisioning Profile' came back as 'provisioning profile'.
            failures.append((key, f"no translation, only casing: {translated!r}"))
            print(f"[{index}/{len(todo)}] SKIP {key!r}: no translation, only casing")
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
        # Spaces and tabs only. A run of "\s" matched the newlines a multi-line prompt is built
        # out of, and polish quietly turned "a\n\nb" into "a b".
        spaced = re.sub(r"[ \t]{2,}", " ", spaced)
        if spaced != value:
            changed += 1
            print(f"  {value!r} -> {spaced!r}")
            if not args.dry_run:
                unit["value"] = spaced

    print(f"{changed} values restyled" + (" (dry run, nothing written)" if args.dry_run else ""))
    if changed and not args.dry_run:
        save_catalog(catalog)


def other_surfaces():
    """Count everything the catalog cannot reach yet, so the coverage number is honest.

    A literal only translates on its own when it reaches the runtime through LocalizedStringKey or
    NSLocalizedString. Interpolated strings need their interpolation folded into %@ first, UIKit
    labels and alert titles are plain Swift strings, storyboard text lives in the .storyboard file,
    and the permission prompts are read from Info.plist.
    """
    interpolated = set()
    uikit = set()
    storyboard = set()
    infoplist = set()

    for top in SOURCE_LANGS:
        for base, _, files in os.walk(os.path.join(ROOT, top)):
            for name in files:
                path = os.path.join(base, name)
                if os.sep + "Tests" + os.sep in path:
                    continue

                if name.endswith(".swift"):
                    text = open(path, encoding="utf-8", errors="replace").read()
                    for pattern in LITERAL_PATTERNS:
                        for match in pattern.finditer(text):
                            if INTERPOLATION.search(match.group(1)):
                                interpolated.add(match.group(1))
                    for pattern in UIKIT_PATTERNS:
                        for match in pattern.finditer(text):
                            literal = match.group(1)
                            if INTERPOLATION.search(literal) or len(literal) < 3:
                                continue
                            uikit.add(swift_key(literal))
                elif name.endswith((".storyboard", ".xib")):
                    text = open(path, encoding="utf-8", errors="replace").read()
                    for pattern in (STORYBOARD_TITLE, STORYBOARD_LABEL):
                        for value in pattern.findall(text):
                            # The label reads "&amp;" in XML but "&" on screen, so the key has to
                            # be the unescaped form or the runtime lookup misses it.
                            value = html.unescape(value)
                            if len(value) > 2 and not value.startswith("$"):
                                storyboard.add(value)
                elif name.endswith("Info.plist"):
                    result = subprocess.run(
                        ["plutil", "-convert", "json", "-o", "-", path],
                        capture_output=True, text=True,
                    )
                    if result.returncode:
                        continue
                    try:
                        plist = json.loads(result.stdout)
                    except json.JSONDecodeError:
                        continue
                    for key, value in plist.items():
                        if isinstance(value, str) and (
                            key.endswith("UsageDescription") or key.endswith("PurposeString")
                        ):
                            infoplist.add(value)

    return {"interpolated": interpolated, "uikit": uikit,
            "storyboard": storyboard, "infoplist": infoplist}


def bar(fraction):
    filled = int(round(BAR_WIDTH * fraction))
    return "#" * filled + "." * (BAR_WIDTH - filled)


BAR_WIDTH = 20


def cmd_report(args):
    literals = literals_in_repo()
    entries = load_catalog()["strings"]

    def chinese(key):
        unit = entries.get(key, {}).get("localizations", {}).get("zh-Hans", {}).get("stringUnit", {})
        return unit.get("value")

    # InfoPlist.xcstrings is keyed by plist key, not by the English sentence, so the lookup above
    # can never match it. Build English value -> Chinese value from that catalog instead.
    plist_catalog = load_infoplist_catalog()
    plist_by_value = {}
    for unit in plist_catalog.values():
        en = unit.get("en", "")
        if en:
            plist_by_value[en] = unit.get("zh-Hans", "")

    def chinese_plist(value):
        return plist_by_value.get(value)

    surfaces = {"swiftui literals": set(literals)}
    other = other_surfaces()
    surfaces.update({
        "interpolated": other["interpolated"],
        "uikit": other["uikit"] - set(literals),
        "storyboard": other["storyboard"],
        "infoplist": other["infoplist"],
    })

    total = sum(len(keys) for keys in surfaces.values())
    covered = 0
    print("每类能自动翻的字符串有多少已经进了中文表：")
    for name, keys in surfaces.items():
        lookup = chinese_plist if name == "infoplist" else chinese
        done = sum(1 for key in keys if lookup(key))
        covered += done
        fraction = done / len(keys) if keys else 0
        note = NOTES.get(name, "")
        print(f"  {name:<18} {bar(fraction)} {done:>4}/{len(keys):<4} {int(fraction * 100):>3}%  {note}")
    print(f"  {'合计':<18} {bar(covered / total)} {covered:>4}/{total:<4} {int(100 * covered / total):>3}%")

    missing = sorted(key for key in literals if not chinese(key))
    print(f"\nSwiftUI 里还没中文的 {len(missing)} 条：")
    for key in missing[: args.show]:
        print(f"  - {key!r}")


NOTES = {
    "swiftui literals": "Text/Button/Label 字面量，加进表就自动生效",
    "interpolated": "带插值，先要把 \\(x) 归一化成 %@ 形态",
    "uikit": "UIKit 直接拼的串，得先包 NSLocalizedString",
    "storyboard": "storyboard 里的标签，靠运行时 NSLocalizedString 重新查表",
    "infoplist": "权限弹窗文案，需要 InfoPlist.xcstrings，且不跟 App 内切换",
}



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

    report = sub.add_parser("report")
    report.add_argument("--show", type=int, default=12)

    args = parser.parse_args()
    if args.command == "scan":
        cmd_scan(args)
    elif args.command == "translate":
        cmd_translate(args)
    elif args.command == "report":
        cmd_report(args)
    else:
        cmd_polish(args)


if __name__ == "__main__":
    main()
