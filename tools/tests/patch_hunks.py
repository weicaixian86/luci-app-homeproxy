#!/usr/bin/env python3
# 校验 unified diff 的 hunk 头计数与实际行数是否一致。
# 改补丁时最容易犯的错：往 + 区加了行却忘了改 @@ -a,b +c,d @@，CI 里 git apply
# 直接报 corrupt patch —— 本地看不出问题，等编译炸了才发现。这里在自检阶段拦住。
#
# 注意：hunk 结束的判定必须排除文件头那三行（diff --git / index / --- / +++），
# 否则 "+++ b/xxx" 会被当成一条新增行，每个「后面还有下一个文件」的 hunk 都会
# 多算一行，报一堆假红。
import re, sys

HEAD = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')
FILE_HEAD = ('diff --git ', 'index ', '--- ', '+++ ', 'new file mode ', 'deleted file mode ',
             'similarity index ', 'rename from ', 'rename to ', 'Binary files ')


def check(path):
    raw = open(path, 'rb').read().decode('utf-8', 'replace')
    lines = raw.split('\n')
    errors = []
    hunks = 0
    i = 0
    while i < len(lines):
        m = HEAD.match(lines[i])
        if not m:
            i += 1
            continue
        hunks += 1
        head_line = i + 1
        old_n = int(m.group(2)) if m.group(2) is not None else 1
        new_n = int(m.group(4)) if m.group(4) is not None else 1
        i += 1
        o = n = 0
        while i < len(lines):
            line = lines[i]
            if HEAD.match(line) or line.startswith(FILE_HEAD) or line == '':
                break
            if line.startswith('+'):
                n += 1
            elif line.startswith('-'):
                o += 1
            elif line.startswith(' ') or line.startswith('\t'):
                o += 1
                n += 1
            else:
                break
            i += 1
        if (o, n) != (old_n, new_n):
            errors.append('%s:%d: hunk declares -%d,+%d but contains -%d,+%d'
                          % (path, head_line, old_n, new_n, o, n))
    return hunks, errors


def main():
    total = 0
    errors = []
    for p in sys.argv[1:]:
        hunks, errs = check(p)
        total += hunks
        errors += errs
    for e in errors:
        print('FAIL ' + e)
    if errors:
        return 1
    print('OK %d hunk(s) counted correctly' % total)
    return 0


if __name__ == '__main__':
    sys.exit(main())
