#!/usr/bin/env python3
"""po/JS gettext consistency check for luci-app-homeproxy.

Extracts every ``_('...')`` string from the LuCI JS sources **and every menu
title from the LuCI menu.d JSON** and verifies that the Simplified Chinese
catalog has a matching, translated entry. The menu titles matter because LuCI
translates them at render time: a tab whose title is missing from the catalog
shows up in English in an otherwise Chinese UI (that is exactly how the
"Configuration File" tab shipped half-translated). Also reports structural
problems in the catalog itself (fuzzy, duplicate msgid, leading or trailing
whitespace in msgid).

Vendored from the ad-hoc ``_pocheck.py`` used during development so CI and any
contributor can run the exact same check:

    python3 tools/tests/pocheck.py

Exit code 0 = clean, 1 = problems found, 2 = missing dependency (polib).
"""

import glob
import json
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
POT = os.path.join(PKG, 'po', 'templates', 'homeproxy.pot')

JS_PATTERNS = (
    'htdocs/luci-static/resources/homeproxy.js',
    'htdocs/luci-static/resources/view/homeproxy/*.js',
)

# LuCI renders menu.d titles through gettext, so they need catalog entries too.
MENU_PATTERNS = (
    'root/usr/share/luci/menu.d/*.json',
)

# ``_(`` starts a gettext call. The arguments are parsed by a real string
# literal scanner below instead of a regex: ``_('a'), _('b')`` on consecutive
# lines is a common shape in this tree, and a ``_\(\s*'...'\s*,\s*'...'\s*\)``
# regex happily spans from the closing paren of one call into the next, which
# produced nonsense msgids such as ``"Congestion control algorithm'),\n\t\t_('QUIC``.
CALL_RE = re.compile(r'\b_\(')

# msgids whose *plain* form is also used by another LuCI package's catalog.
# LuCI merges every /usr/lib/lua/luci/i18n/*.lmo into one sfh-hashed table
# (cbi.js:18) and the last writer wins, so another package's translation
# silently replaces ours -- e.g. ddns ships 「未在运行」 for "Not Running" and
# that is what the status card actually rendered, no matter what this catalog
# says. A gettext context (``_('Not Running', 'homeproxy')``) makes the lookup
# key "homeproxy\x01Not Running" (po2lmo.c:166), which no other package claims.
# Listed explicitly so dropping a context turns this check red instead of
# quietly regressing on the device.
CTX_REQUIRED = (
    'Not Running',            # ddns: 未在运行
    'Cancel',                 # base / ddns / dockerman / oaf / package-manager: 取消
    'Checking...',            # ota: 检查中...
    'Collecting data...',     # base: 收集数据中... / ddnsto + linkease: 收集数据...
    'Host',                   # base: 主机
    'non-empty value',        # base: 不能为空
    'unique value',           # base: 唯一值
    # oaf renders these as 周日/周一/... while this package needs the bare
    # 日/一/... because they are spliced into "每周%s %s". oaf has no "Thu",
    # so without a context the same row mixed 周四 with 周五. Thu keeps the
    # context too, purely so the array stays uniform.
    'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat',
)

# §六-14 of the spec: a msgid must be an English source string. A Chinese
# msgid shows up verbatim in non-Chinese locales, so it is a defect rather
# than a shortcut -- the whole configuration-file page was written that way
# once and nothing caught it.
CJK_RE = re.compile(r'[\u4e00-\u9fa5]')

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


def _skip_string(src, i):
    """``src[i]`` is a quote character; return the index just past the literal."""
    quote = src[i]
    i += 1
    while i < len(src):
        ch = src[i]
        if ch == '\\':
            i += 2
            continue
        if ch == quote:
            return i + 1
        i += 1
    return i


def _skip_noise(src, i):
    """Skip whitespace and comments, returning the index of the next code char."""
    while i < len(src):
        ch = src[i]
        if ch in ' \t\r\n':
            i += 1
        elif src.startswith('//', i):
            end = src.find('\n', i)
            i = len(src) if end < 0 else end + 1
        elif src.startswith('/*', i):
            end = src.find('*/', i)
            i = len(src) if end < 0 else end + 2
        else:
            break
    return i


def _read_call_args(src, i):
    """Parse the argument list of a ``_(`` call whose '(' ends at ``i - 1``.

    Returns ``(args, end)``: ``args`` holds ``(quote, raw_text)`` for every
    argument that is a single string literal (or a ``'a' + 'b'`` concatenation
    of literals), ``None`` for anything else. ``end`` is just past ``)``.

    A real scanner is required here: a regex such as ``_\\('a'\\s*,\\s*'b'\\)``
    matches across two neighbouring one-argument calls and invents msgids like
    ``"Congestion control algorithm'),\\n\\t\\t_('QUIC"`` -- exactly what happened
    when this check was first taught about contexts.
    """
    args = []
    current = None      # accumulating literal text for the current argument
    depth = 0
    while i < len(src):
        ch = src[i]
        if ch in '"\'':
            end = _skip_string(src, i)
            if current is None:
                current = src[i + 1:end - 1]
            else:
                # gettext extracts the concatenated form of _('a' + 'b').
                current += src[i + 1:end - 1]
            i = end
            continue
        if ch == '(':
            depth += 1
        elif ch == ')':
            if depth == 0:
                args.append(current)
                return args, i + 1
            depth -= 1
        elif ch == ',' and depth == 0:
            args.append(current)
            current = None
            i += 1
            continue
        elif ch in ' \t\r\n+':
            # Whitespace and the '+' of a literal concatenation keep the
            # current argument going; anything else means the argument is an
            # expression, not a translatable literal.
            i += 1
            continue
        elif ch in '/':
            after = _skip_noise(src, i)
            if after != i:
                i = after
                continue
            current = None
        else:
            current = None
        i += 1
    return args, i


def js_strings():
    """Every ``_('...')`` / ``_('...', 'ctx')`` call, keyed to its source file.

    Returns ``(files, found)`` where ``found`` maps ``(msgid, msgctxt)`` to the
    file it came from; ``msgctxt`` is ``None`` for a plain call. Calls carrying
    a context must be matched against a catalog entry with the same
    ``msgctxt`` -- a plain msgid entry would not be found at runtime, because
    po2lmo keys contextual entries as "context\\x01msgid" (po2lmo.c:166) and
    cbi.js:18 builds the lookup key the same way.
    """
    files = []
    for pattern in JS_PATTERNS:
        files += sorted(glob.glob(os.path.join(PKG, pattern)))

    found = {}
    for path in files:
        with open(path, encoding='utf-8') as handle:
            src = handle.read()
        rel = os.path.relpath(path, ROOT)
        for match in CALL_RE.finditer(src):
            args, _end = _read_call_args(src, match.end())
            if not args or not args[0]:
                continue
            value = unescape_js(args[0])
            if not value:
                continue
            context = None
            if len(args) > 1 and args[1]:
                context = unescape_js(args[1])
            found.setdefault((value, context), rel)
    return files, found


def menu_titles():
    """Every ``title`` in the LuCI menu tree, keyed to its source file."""
    found = {}
    for pattern in MENU_PATTERNS:
        for path in sorted(glob.glob(os.path.join(PKG, pattern))):
            with open(path, encoding='utf-8') as handle:
                tree = json.load(handle)
            if not isinstance(tree, dict):
                continue
            for body in tree.values():
                if isinstance(body, dict) and isinstance(body.get('title'), str):
                    found.setdefault(body['title'], os.path.relpath(path, ROOT))
    return found


def main():
    if not os.path.isfile(PO):
        sys.stderr.write('pocheck: catalog not found: %s\n' % PO)
        return 1

    catalog = polib.pofile(PO, encoding='utf-8')
    live = [entry for entry in catalog if not entry.obsolete]
    # (msgid, msgctxt) is the real catalog key: two entries may share a msgid
    # as long as their contexts differ, and a contextual call only resolves
    # against the entry carrying that same context.
    msgkeys = [(entry.msgid, entry.msgctxt) for entry in live]
    msgid_set = set(msgkeys)
    plain_msgids = {entry.msgid for entry in live if not entry.msgctxt}

    # Obsolete (#~) entries whose msgid collides with a live entry: msgmerge
    # counts both as definitions and dies with "duplicate message
    # definition" -- an error only CI's i18n-update.pl shows, polib parses
    # the file happily. Catch it here so it never reaches CI again
    # (2026-10-31: an obsolete "Update time" blocked the whole build after a
    # live "Update time" was reintroduced).
    stale_collisions = sorted({e.msgid for e in catalog if e.obsolete and e.msgid in plain_msgids})

    files, found = js_strings()
    menu = menu_titles()

    # Contexts are not cosmetic: the ones in CTX_REQUIRED are msgids that
    # another installed package also translates, and LuCI's merged
    # /admin/translations table (cbi.js:18, sfh-hashed) lets the later entry
    # win. Both halves must agree -- a call without a context silently reads
    # the other package's wording, and a catalog entry without msgctxt is
    # unreachable from a contextual call.
    #
    # ctx_plain_call : required msgid still called without a context somewhere
    # ctx_no_entry   : contextual call whose msgctxt entry is missing in po
    # ctx_foreign    : catalog carries a context other than 'homeproxy'
    ctx_plain_call = sorted(msgid for msgid in CTX_REQUIRED
                            if (msgid, None) in found)
    ctx_no_entry = sorted(msgid for msgid in CTX_REQUIRED
                          if (msgid, 'homeproxy') not in msgid_set)
    ctx_foreign = sorted({entry.msgctxt for entry in live
                          if entry.msgctxt and entry.msgctxt != 'homeproxy'})
    # Any contextual call in the tree, not just the known collisions.
    ctx_mismatch = sorted(msgid for (msgid, ctx) in found
                          if ctx and (msgid, ctx) not in msgid_set)
    ctx_problems = (len(ctx_plain_call) + len(ctx_no_entry) + len(ctx_foreign)
                    + len(ctx_mismatch))

    # msgmerge -U -N matches on (msgctxt, msgid). A po entry carrying a context
    # whose template has no such context is unmatched, so msgmerge marks it
    # obsolete and re-adds an untranslated plain entry -- the translation
    # silently disappears on the next rescan (Rescan-Translation.yml runs
    # i18n-scan.pl then i18n-update.pl on every push touching htdocs/ or root/).
    # Only contextual entries are compared: the checked-in template has other
    # long-standing drift, and that is a separate concern.
    pot_drift = []
    if os.path.isfile(POT):
        template = polib.pofile(POT, encoding='utf-8')
        # Same (msgid, msgctxt) ordering as msgkeys -- mixing the two orders
        # makes every contextual entry look like drift.
        potkeys = {(entry.msgid, entry.msgctxt) for entry in template if entry.msgid}
        pot_drift = sorted('%r [ctx=%r]' % (msgid, ctx)
                           for (msgid, ctx) in msgkeys
                           if msgid and ctx and (msgid, ctx) not in potkeys)

    # Menu titles are rendered by LuCI without a context, so they match plain
    # msgids only.
    missing_keys = sorted(key for key in found if key not in msgid_set)
    missing_menu = sorted(key for key in menu if key not in plain_msgids)
    missing = missing_keys + missing_menu
    cjk = sorted(key[0] for key in found if CJK_RE.search(key[0]))
    untranslated = [entry for entry in live if not entry.msgstr and not entry.msgstr_plural]
    fuzzy = [entry for entry in live if 'fuzzy' in entry.flags]
    duplicates = sorted({key for key in msgkeys if msgkeys.count(key) > 1})
    padded = [entry.msgid for entry in live
              if entry.msgid and entry.msgid != entry.msgid.strip()]

    print('js files    : %d' % len(files))
    print('js strings  : %d' % len(found))
    print('menu titles : %d' % len(menu))
    print('po entries  : %d' % len(live))
    print('msgctxt     : %d' % len([e for e in live if e.msgctxt]))
    print('missing     : %d' % len(missing))
    print('cjk msgids  : %d' % len(cjk))
    print('untranslated: %d' % len(untranslated))
    print('fuzzy       : %d' % len(fuzzy))
    print('duplicates  : %d' % len(duplicates))
    print('msgid padded: %d' % len(padded))
    print('ctx required: %d' % len(CTX_REQUIRED))
    print('ctx problems: %d' % ctx_problems)
    print('pot drift   : %d' % len(pot_drift))

    for msgid in ctx_plain_call[:20]:
        print('  NO CONTEXT %r -- another package translates this msgid too '
              '(add the "homeproxy" context)' % msgid)
    for msgid in ctx_no_entry[:20]:
        print('  NO MSGCTXT %r -- the catalog has no "homeproxy" context for it' % msgid)
    for msgid in ctx_mismatch[:20]:
        print('  ORPHAN CTX %r -- called with a context the catalog lacks' % msgid)
    for ctx in ctx_foreign[:20]:
        print('  FOREIGN CTX %r -- only "homeproxy" is used by this package' % ctx)
    for key in pot_drift[:20]:
        print('  POT DRIFT %s -- msgmerge would mark this obsolete on the next rescan' % key)
    for key in missing_keys[:40]:
        msgid, ctx = key
        label = '%r [ctx=%r]' % (msgid, ctx) if ctx else repr(msgid)
        print('  MISSING %s  <- %s' % (label, found[key]))
    for key in missing_menu[:40]:
        print('  MISSING menu title %r  <- %s' % (key, menu[key]))
    for key in cjk[:20]:
        print('  CJK MSGID %r  (msgids must be English)' % key)
    for entry in untranslated[:20]:
        print('  UNTRANSLATED %r' % entry.msgid)
    for key in duplicates[:20]:
        print('  DUPLICATE %r' % (key,))
    for key in padded[:20]:
        print('  PADDED %r' % key)

    problems = (len(missing) + len(cjk) + len(untranslated) + len(fuzzy)
                + len(duplicates) + len(padded) + len(stale_collisions)
                + ctx_problems + len(pot_drift))
    for key in stale_collisions[:20]:
        print('  STALE #~ entry collides with live msgid %r -- msgmerge will refuse this file' % key)
    if problems:
        print('\npocheck: FAILED (%d problem(s))' % problems)
        return 1

    print('\npocheck: clean')
    return 0


if __name__ == '__main__':
    sys.exit(main())
