#!/usr/bin/env python3
"""Approximate syntax check for ucode sources.

There is no ucode interpreter on the CI runner (and none on a Windows dev box),
but ucode's syntax is close enough to JavaScript that `node --check` catches
real breakage (unbalanced braces/parens, stray tokens, unterminated strings).

`import ... from '...'` / `'use strict'` / shebang lines are stripped because
they are not valid in that position for Node's parser, then the body is wrapped
in a function so that top-level `return` is legal.

Usage: python3 tools/tests/ucparse.py <outdir> <file.uc> [file.uc ...]
Writes <outdir>/<name>.js for each input; exits 0 on success.
"""

import os
import re
import sys

IMPORT_RE = re.compile(r"^\s*import\s+.*from\s+['\"][^'\"]*['\"]\s*;?\s*$")


def wrap(src):
    out = []
    for line in src.splitlines():
        if line.startswith('#!'):
            continue
        if IMPORT_RE.match(line):
            continue
        if line.strip() in ("'use strict';", '"use strict";'):
            continue
        out.append(line)
    return 'function __ucode_wrap() {\n' + '\n'.join(out) + '\n}\n'


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2

    outdir, files = argv[1], argv[2:]
    os.makedirs(outdir, exist_ok=True)

    for path in files:
        if not os.path.isfile(path):
            sys.stderr.write('ucparse: missing file %s\n' % path)
            return 1
        with open(path, encoding='utf-8') as handle:
            src = handle.read()
        name = os.path.basename(path) + '.js'
        target = os.path.join(outdir, name)
        # newline='\n': without it Windows text mode writes CRLF and the
        # shell loop ends up with a trailing CR glued to every filename.
        with open(target, 'w', encoding='utf-8', newline='\n') as handle:
            handle.write(wrap(src))
        # Forward slashes: the output is consumed by a POSIX shell (Git Bash on
        # Windows would treat "dir\file.js" as a single literal filename).
        print(target.replace(os.sep, '/'))

    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
