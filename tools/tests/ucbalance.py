#!/usr/bin/env python3
"""Balanced-delimiter check for ucode sources.

Why this exists instead of trusting `node --check`: ucode files contain
multi-line `import { ... } from '...'` and template literals, and Node ends
up parsing the wrapped result as an ES module. 0.2.4 shipped with a stray
`)` on `update_subscriptions.uc:1583` (`)));` where `));` was meant) and the
script refused to start on the device:

    Syntax error: Unexpected token
    Expecting ';'
    In /etc/homeproxy/scripts/update_subscriptions.uc, line 1583

`node --check` had reported success on that exact file, because the leftover
`import {` made Node switch to module parsing and the file was never checked
as a script. An unbalanced delimiter is what ucode trips over first, so it
gets its own lexer-level check that does not depend on any parser's mode.

This walks the source the way ucode's lexer does -- single/double quoted
strings, template literals with `${}` interpolation, `//` and `/* */`
comments -- and reports the first delimiter that closes something that is
not open, or a file that ends with delimiters still open.

Usage: python3 tools/tests/ucbalance.py <file.uc> [file.uc ...]
Exit code 0 when every file balances, 1 otherwise.
"""

import sys

PAIRS = {')': '(', ']': '[', '}': '{'}
NAMES = {'(': ')', '[': ']', '{': '}'}

# A `/` starts a regex literal only where a value may *begin*. After these
# characters the parser is still waiting for an operand, so `/re/` is valid
# there; after an identifier, a number, `)` or `]` the same `/` is division.
REGEX_OK_PREV = set('(,=:[!&|?{};+-*/%<>~^')

# Marker for "a value just ended" (string, template, regex, identifier tail).
VALUE = 'V'


class Scanner:
    def __init__(self, path, src):
        self.path = path
        self.src = src
        self.i = 0
        self.line = 1
        self.col = 1
        self.stack = []  # (opener, line, col)
        self.errors = []
        self.prev = None  # last significant char, for regex-vs-division

    # -- low level -------------------------------------------------------
    def peek(self, k=0):
        j = self.i + k
        return self.src[j] if j < len(self.src) else ''

    def step(self, k=1):
        for _ in range(k):
            if self.i >= len(self.src):
                return
            if self.src[self.i] == '\n':
                self.line += 1
                self.col = 1
            else:
                self.col += 1
            self.i += 1

    def error(self, line, col, msg):
        # Only the first unbalanced delimiter matters: everything after it is
        # a cascade of misleading follow-on errors.
        if not self.errors:
            self.errors.append((line, col, msg))

    def open(self, ch):
        self.stack.append((ch, self.line, self.col))
        self.prev = ch
        self.step()

    def close(self, ch):
        self.prev = ch
        want = PAIRS[ch]
        if not self.stack:
            self.error(self.line, self.col,
                       "unexpected '%s' with nothing open" % ch)
        elif self.stack[-1][0] != want:
            opener, oline, ocol = self.stack[-1]
            self.error(self.line, self.col,
                       "'%s' closes '%s' opened at line %d col %d "
                       "(expected '%s')" % (ch, opener, oline, ocol,
                                            NAMES[opener]))
            self.stack.pop()
        else:
            self.stack.pop()
        self.step()

    # -- grammar-ish walking --------------------------------------------
    def skip_line_comment(self):
        while self.i < len(self.src) and self.peek() != '\n':
            self.step()

    def skip_block_comment(self):
        self.step(2)
        while self.i < len(self.src):
            if self.peek() == '*' and self.peek(1) == '/':
                self.step(2)
                return
            self.step()
        self.error(self.line, self.col, "unterminated /* comment")

    def skip_string(self):
        quote = self.peek()
        sl, sc = self.line, self.col
        self.step()
        while self.i < len(self.src):
            ch = self.peek()
            if ch == '\\':
                self.step(2)
                continue
            if ch == quote:
                self.step()
                self.prev = VALUE
                return
            if ch == '\n':
                # ucode does not allow a raw newline inside a quoted string;
                # report it here rather than silently eating the rest of file.
                self.error(sl, sc, "unterminated %s string" % quote)
                return
            self.step()
        self.error(sl, sc, "unterminated %s string" % quote)

    def skip_regex(self):
        """Consume /re/flags. ucode supports regex literals (match(n, /^x/))."""
        sl, sc = self.line, self.col
        self.step()  # opening slash
        in_class = False
        while self.i < len(self.src):
            ch = self.peek()
            if ch == '\\':
                self.step(2)
                continue
            if ch == '[':
                in_class = True
                self.step()
                continue
            if ch == ']':
                in_class = False
                self.step()
                continue
            if ch == '/' and not in_class:
                self.step()
                while self.peek() and self.peek() in 'gimsuy':
                    self.step()
                self.prev = VALUE
                return
            if ch == '\n':
                self.error(sl, sc, "unterminated regex literal")
                return
            self.step()
        self.error(sl, sc, "unterminated regex literal")

    def walk_template(self):
        """Consume a `...` literal, recursing into ${ ... } expressions."""
        self.step()  # opening backtick
        while self.i < len(self.src):
            ch = self.peek()
            if ch == '\\':
                self.step(2)
                continue
            if ch == '`':
                self.step()
                self.prev = VALUE
                return
            if ch == '$' and self.peek(1) == '{':
                self.step(2)
                self.walk_code(in_expr=True)
                self.prev = VALUE
                continue
            self.step()
        self.error(self.line, self.col, "unterminated template literal")

    def walk_code(self, in_expr=False):
        base = len(self.stack)
        while self.i < len(self.src):
            ch = self.peek()
            nxt = self.peek(1)

            if ch == '/' and nxt == '/':
                self.skip_line_comment()
                continue
            if ch == '/' and nxt == '*':
                self.skip_block_comment()
                continue
            if ch == '/':
                # `/` is a regex literal only where a value may begin.
                if self.prev is None or self.prev in REGEX_OK_PREV:
                    self.skip_regex()
                else:
                    self.prev = ch
                    self.step()
                continue
            if ch in ('"', "'"):
                self.skip_string()
                continue
            if ch == '`':
                self.walk_template()
                continue

            if ch in '([{':
                self.open(ch)
                continue
            if ch in ')]}':
                if in_expr and ch == '}' and len(self.stack) == base:
                    # This '}' terminates the ${ ... } we were called for.
                    self.step()
                    return
                self.close(ch)
                continue
            if not ch.isspace():
                self.prev = ch
            self.step()

    def run(self):
        if self.src.startswith('\ufeff'):
            self.step()
        self.walk_code()
        for opener, oline, ocol in self.stack:
            self.error(oline, ocol,
                       "'%s' opened here is never closed" % opener)
        return self.errors


def check_file(path):
    with open(path, encoding='utf-8') as handle:
        src = handle.read()
    return Scanner(path, src).run()


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2

    failed = 0
    for path in argv[1:]:
        errors = check_file(path)
        if errors:
            failed += 1
            line, col, msg = errors[0]
            sys.stderr.write('%s:%d:%d: %s\n' % (path, line, col, msg))
        else:
            print('ok %s' % path)

    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
