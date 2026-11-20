#!/usr/bin/env python3
"""Convert the Android app's strings.xml files into an iOS String Catalog plus a Swift accessor.

Keys stay the Android resource names so the two apps can be kept in step. Pass the Android app's
resource directory (the one holding values/, values-de/, ...), from a checkout of the Android repo:
    python3 scripts/convert-strings.py <android-checkout>/app/src/main/res
Writes App/BitChord/Resources/Localizable.xcstrings and App/BitChord/Support/L10n.swift, found
relative to this script.
"""
import json, re, sys, xml.etree.ElementTree as ET
from pathlib import Path

if len(sys.argv) != 2:
    sys.exit("usage: convert-strings.py <android-res-dir>\n"
             "  e.g. python3 scripts/convert-strings.py ../BitChord/app/src/main/res")
ROOT = Path(__file__).resolve().parents[1]
RES = Path(sys.argv[1])
OUT_CATALOG = ROOT / "App/BitChord/Resources/Localizable.xcstrings"
OUT_SWIFT = ROOT / "App/BitChord/Support/L10n.swift"
# Android resource qualifier -> iOS localization identifier.
LOCALES = {"values": "en", "values-de": "de", "values-es": "es", "values-fr": "fr", "values-he": "he",
           "values-hi": "hi", "values-id": "id", "values-it": "it", "values-ja": "ja", "values-pl": "pl",
           "values-pt": "pt", "values-ru": "ru", "values-th": "th", "values-tr": "tr", "values-vi": "vi",
           "values-zh": "zh-Hans"}
SPEC = re.compile(r"%(?:(\d+)\$)?([-#+ 0,(]*\d*(?:\.\d+)?)([sdf])")

def text_of(el):
    # Flatten inline markup (<b>, <xliff:g>) to its text; Android escapes to literal characters.
    s = "".join(el.itertext())
    s = s.replace("\\'", "'").replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t").replace("\\@", "@").replace("\\?", "?")
    if len(s) >= 2 and s[0] == s[-1] == '"':
        s = s[1:-1]
    return s

def specs(s):
    return [(m.group(1), m.group(3)) for m in SPEC.finditer(s)]

def to_ios(s):
    def repl(m):
        pos, flags, conv = m.group(1), m.group(2), m.group(3)
        head = f"%{pos}$" if pos else "%"
        return head + flags + {"s": "@", "d": "lld", "f": "f"}[conv]
    return SPEC.sub(repl, s)

def load(qualifier):
    path = RES / qualifier / "strings.xml"
    tree = ET.parse(path)
    strings, plurals = {}, {}
    for el in tree.getroot():
        name = el.get("name")
        if el.tag == "string":
            strings[name] = text_of(el)
        elif el.tag == "plurals":
            plurals[name] = {item.get("quantity"): text_of(item) for item in el.findall("item")}
    return strings, plurals

def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}

base_strings, base_plurals = load("values")
catalog = {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
per_locale = {loc: load(q) for q, loc in LOCALES.items()}

for key, en in base_strings.items():
    has_args = bool(specs(en))
    locs = {}
    for loc, (strings, _) in per_locale.items():
        v = strings.get(key)
        if v is None:
            continue
        locs[loc] = unit(to_ios(v) if has_args else v)
    catalog["strings"][key] = {"extractionState": "manual", "localizations": locs}

def formats_text(forms):
    """Plurals whose forms print a pre-formatted count (%1$s) rather than the number itself."""
    return any(conv == "s" for v in forms.values() for _, conv in specs(v))

for key, en_forms in base_plurals.items():
    locs = {}
    text_count = formats_text(en_forms)
    for loc, (_, plurals) in per_locale.items():
        forms = plurals.get(key)
        if not forms:
            continue
        if not text_count:
            locs[loc] = {"variations": {"plural": {q: unit(to_ios(v)) for q, v in forms.items()}}}
        elif len(forms) == 1:
            # Languages without plural forms (th, ja, zh...): one string, the count argument goes unused.
            locs[loc] = unit(to_ios(next(iter(forms.values()))))
        else:
            # The text count is argument 1; plural selection keys on the numeric count, argument 2.
            locs[loc] = {"stringUnit": {"state": "translated", "value": "%#@count@"},
                         "substitutions": {"count": {"argNum": 2, "formatSpecifier": "lld",
                                                     "variations": {"plural": {q: unit(to_ios(v)) for q, v in forms.items()}}}}}
    catalog["strings"][key] = {"extractionState": "manual", "localizations": locs}

OUT_CATALOG.parent.mkdir(parents=True, exist_ok=True)
OUT_CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

def camel(name):
    parts = re.split(r"[_\W]+", name)
    out = parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:])
    if out[0].isdigit():
        out = "_" + out
    return out

SWIFT_KEYWORDS = {"default", "repeat", "import", "private", "public", "internal", "return", "switch", "case",
                  "true", "false", "nil", "self", "Self", "class", "struct", "enum", "protocol", "func", "var",
                  "let", "in", "for", "while", "if", "else", "do", "try", "catch", "throw", "throws", "is", "as",
                  "operator", "static", "subscript", "init", "deinit", "extension", "where", "break", "continue",
                  "fallthrough", "guard", "defer", "inout", "associatedtype", "typealias", "super", "any", "some"}

def ident(name):
    c = camel(name)
    return f"`{c}`" if c in SWIFT_KEYWORDS else c

def swift_arg_type(conv):
    return {"s": "String", "d": "Int", "f": "Double"}[conv]

lines = ["// Generated by scripts/convert-strings.py from the Android app's strings.xml. Do not edit by hand.",
         "// Keys are the Android resource names; values come from Resources/Localizable.xcstrings.",
         "import Foundation", "",
         "enum L10n {",
         "    /// Looks a key up in the app's string catalog, honouring the in-app language override.",
         "    static func tr(_ key: String) -> String {",
         "        NSLocalizedString(key, tableName: \"Localizable\", bundle: LanguageBundle.current, comment: \"\")",
         "    }", ""]
for key, en in sorted(base_strings.items()):
    sp = specs(en)
    if not sp:
        lines.append(f"    /// {en.splitlines()[0][:100] if en else ''}")
        lines.append(f"    static var {ident(key)}: String {{ tr(\"{key}\") }}")
        continue
    # Arguments in positional order.
    positions = {}
    for i, (pos, conv) in enumerate(sp):
        positions[int(pos) if pos else i + 1] = conv
    params = ", ".join(f"_ a{p}: {swift_arg_type(c)}" for p, c in sorted(positions.items()))
    args = ", ".join(f"a{p}" for p in sorted(positions))
    lines.append(f"    /// {en.splitlines()[0][:100]}")
    lines.append(f"    static func {ident(key)}({params}) -> String {{ String(format: tr(\"{key}\"), locale: LanguageBundle.locale, {args}) }}")
for key, forms in sorted(base_plurals.items()):
    lines.append(f"    /// {forms.get('other', '')[:100]}")
    if formats_text(forms):
        lines.append(f"    static func {ident(key)}(_ count: Int, formatted: String) -> String {{ String(format: tr(\"{key}\"), locale: LanguageBundle.locale, formatted, count) }}")
    else:
        lines.append(f"    static func {ident(key)}(_ count: Int) -> String {{ String(format: tr(\"{key}\"), locale: LanguageBundle.locale, count) }}")
lines += ["}", ""]
OUT_SWIFT.parent.mkdir(parents=True, exist_ok=True)
OUT_SWIFT.write_text("\n".join(lines), encoding="utf-8")
print(f"{len(base_strings)} strings, {len(base_plurals)} plurals, {len(LOCALES)} locales")
