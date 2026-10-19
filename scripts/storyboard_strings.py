#!/usr/bin/env python3
"""Extract the user-visible strings a storyboard hard-codes, as .strings keys.

Interface Builder stores its text on the element that renders it, so a localized storyboard is a
`<Name>.strings` file whose keys are `<elementID>.<attribute>`. Hand-typing those IDs is how these
files get silently wrong, so generate the skeleton and keep only the values.

  scripts/storyboard_strings.py extract AltStore/Settings/Settings.storyboard
  scripts/storyboard_strings.py check AltStore/Settings/Settings.storyboard AltStore/Settings/zh-Hans.lproj/Settings.strings

`check` fails when the storyboard gained text the .strings does not cover, which is the failure
mode worth catching: an untranslated label on a screen nobody looks at again.
"""

import re
import sys
import xml.etree.ElementTree as ET

# Attributes UIKit renders as text. developerTeams is deliberately absent: it is not user facing.
TEXT_ATTRIBUTES = ("text", "title", "placeholder", "prompt")


def entries(path):
    """Yield (key, english) for every element carrying text, in document order."""
    root = ET.parse(path).getroot()
    seen = set()
    for element in root.iter():
        identifier = element.get("id")
        if not identifier:
            continue
        for attribute in TEXT_ATTRIBUTES:
            value = element.get(attribute)
            if value is None or not value.strip():
                continue
            key = f"{identifier}.{attribute}"
            if key in seen:
                continue
            seen.add(key)
            yield key, value


# No ^ anchor: finditer is used over the whole file, and ^ without re.MULTILINE only matches the
# very first character, which silently matched nothing once the leading comment was stripped.
ENTRY = re.compile(r'"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')


def parse_strings(path):
    """Read a generated .strings table.

    Comments are stripped as blocks first. Matching the entry pattern rather than splitting on the
    first equals sign is what keeps a comment containing = from being read as a key, and keeps a
    value containing ; from being cut short.
    """
    text = open(path, encoding="utf-8").read()
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    text = re.sub(r"^\s*//.*$", "", text, flags=re.MULTILINE)
    return {match.group(1): match.group(2) for match in ENTRY.finditer(text)}


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1

    command, storyboard = sys.argv[1], sys.argv[2]
    found = list(entries(storyboard))

    if command == "extract":
        print(f"// {storyboard}: {len(found)} strings. Values still English; translate them.\n")
        for key, value in found:
            print(f'"{key}" = "{value}";')
        return 0

    if command == "check":
        translations = parse_strings(sys.argv[3])
        missing = [(key, value) for key, value in found if key not in translations]
        untranslated = [
            (key, value) for key, value in found
            if key in translations and translations[key] == value
        ]
        print(f"{storyboard}: {len(found)} strings, {len(translations)} keys in the table")
        for key, value in missing:
            print(f"  missing    {key}  {value!r}")
        for key, value in untranslated:
            print(f"  untranslated {key}  {value!r}")
        return 1 if missing else 0

    print(f"unknown command {command}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
