#!/usr/bin/env python3
"""po/JS gettext consistency check for luci-app-homeproxy.

Extracts every ``_('...')`` string from the LuCI JS sources and verifies that
the Simplified Chinese catalog has a matching, translated entry. Also reports
structural problems in the catalog itself (fuzzy, duplicate msgid, leading or
trailing whitespace in msgid).

Vendored from the ad-hoc ``_pocheck.py`` used during development so CI and any
contributor can run the exact same check:

    python3 tools/tests/pocheck.py

Exit code 0 = clean, 1 = problems found, 2 = missing dependency (polib).
"""

import glob
import os
import re
import sys

try:
    import polib
except ImportError:  # pragma: no cover - dependency guard
    sys.stderr.write('pocheck: python module "polib" is required (pip install polib)\n')
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PKG = os.path.join(ROOT, 'luci-app-homeproxy')
PO = os.path.join(PKG, 'po', 'zh_Hans', 'homeproxy.po')

JS_PATTERNS = (
    'htdocs/luci-static/resources/homeproxy.js',
    'htdocs/luci-static/resources/view/homeproxy/*.js',
)

# _('...') / _("...") — the value may span lines and use escaped quotes.
STR_RE = re.compile(r"""_\(\s*(['"])(.*?)(?<!\\)\1\s*\)""", re.S)

ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', '"': '"', "'": "'", '\\': '\\'}


def unescape_js(text):
    out = []
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == '\\' and i + 1 < len(text):
            nxt = text[i + 1]
            if nxt == 'u' and i + 5 < len(text):
                try:
                    out.append(chr(int(text[i + 2:i + 6], 16)))
                    i += 6
                    continue
                except ValueError:
                    pass
            out.append(ESCAPES.get(nxt, nxt))
            i += 2
            continue
        out.append(ch)
        i += 1
    return ''.join(out)


def js_strings():
    files = []
    for pattern in JS_PATTERNS:
        files += sorted(glob.glob(os.path.join(PKG, pattern)))

    found = {}
    for path in files:
        with open(path, encoding='utf-8') as handle:
            src = handle.read()
        for match in STR_RE.finditer(src):
            value = unescape_js(match.group(2))
            # gettext extracts the concatenated form of _('a' + 'b').
            value = re.sub(r"'\s*\+\s*'", '', value)
            if value:
                found.setdefault(value, os.path.relpath(path, ROOT))
    return files, found


def main():
    if not os.path.isfile(PO):
        sys.stderr.write('pocheck: catalog not found: %s\n' % PO)
        return 1

    catalog = polib.pofile(PO, encoding='utf-8')
    live = [entry for entry in catalog if not entry.obsolete]
    msgids = [entry.msgid for entry in live]
    msgid_set = set(msgids)

    files, found = js_strings()

    missing = sorted(key for key in found if key not in msgid_set)
    untranslated = [entry for entry in live if not entry.msgstr and not entry.msgstr_plural]
    fuzzy = [entry for entry in live if 'fuzzy' in entry.flags]
    duplicates = sorted({key for key in msgids if msgids.count(key) > 1})
    padded = [entry.msgid for entry in live
              if entry.msgid and entry.msgid != entry.msgid.strip()]

    print('js files    : %d' % len(files))
    print('js strings  : %d' % len(found))
    print('po entries  : %d' % len(live))
    print('missing     : %d' % len(missing))
    print('untranslated: %d' % len(untranslated))
    print('fuzzy       : %d' % len(fuzzy))
    print('duplicates  : %d' % len(duplicates))
    print('msgid padded: %d' % len(padded))

    for key in missing[:40]:
        print('  MISSING %r  <- %s' % (key, found[key]))
    for entry in untranslated[:20]:
        print('  UNTRANSLATED %r' % entry.msgid)
    for key in duplicates[:20]:
        print('  DUPLICATE %r' % key)
    for key in padded[:20]:
        print('  PADDED %r' % key)

    problems = len(missing) + len(untranslated) + len(fuzzy) + len(duplicates) + len(padded)
    if problems:
        print('\npocheck: FAILED (%d problem(s))' % problems)
        return 1

    print('\npocheck: clean')
    return 0


if __name__ == '__main__':
    sys.exit(main())
