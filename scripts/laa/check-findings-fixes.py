#!/usr/bin/env python3
"""Judges the findings' own `fixed <sha>` claims against the repository.

A row in `docs/laa/findings/<month>-<platform>.md` says `fixed <sha>` once its
change is on master. Two ways that claim can stop being true, both silent:

* the sha is not in master's history at all (committed on a branch and dropped);
* a later commit put a file the fix touched back to its pre-fix blob, so the
  fix is gone although the row still reads `fixed`.

The second happened on 2026-11-28: `c0cf83c79` wrote the task bar's values and
`b244550d2` restored the file to its pre-fix blob while the row still said
`fixed c0cf83c79`; the same commit moved the row to `open`, which is the
convention this check relies on. A file that a later commit intentionally
reverts is fine *provided the row stops claiming the fix*, so only a row that
still says `fixed` is judged.

A row is judged on the files it names in its own cells: a fix commit can touch
several screens, and one of them being reverted on purpose does not undo the
row about another. A row that names no file is judged on every code file its
commit touched.

Shas that do not exist in this repository are skipped with a count, never
failed: one findings file can name another repo's commits.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

FIXED = re.compile(r'\bfixed\s+([0-9a-f]{7,40})\b')
MENTIONED = re.compile(r'[A-Za-z0-9_./-]+\.(?:swift|py|mjs|sh)\b')


def git(repo, *args, check=True):
    result = subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or 'git %s failed' % ' '.join(args))
    return result


def rows(findings_dir):
    """(file, line number, sha, files the row names) for every row that claims a fix."""
    for path in sorted(Path(findings_dir).glob('*.md')):
        for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            if not line.startswith('|'):
                continue
            named = {Path(name).name for name in MENTIONED.findall(line)}
            for sha in FIXED.findall(line):
                yield path, number, sha, named


def judge(repo, findings_dir, base='master'):
    findings, skipped, problems = 0, 0, []
    seen = set()
    for path, number, sha, named in rows(findings_dir):
        resolved = git(repo, 'rev-parse', '--verify', '--quiet', sha + '^{commit}', check=False)
        if resolved.returncode != 0:
            skipped += 1
            continue
        if (sha, number) in seen:
            continue
        seen.add((sha, number))
        findings += 1
        commit = resolved.stdout.strip()
        where = '%s:%d (fixed %s)' % (path.name, number, sha)
        if git(repo, 'merge-base', '--is-ancestor', commit, base, check=False).returncode != 0:
            problems.append('%s: not in %s history' % (where, base))
            continue
        touched = git(repo, 'show', '--name-only', '--diff-filter=AM', '--format=', commit).stdout.split()
        for name in touched:
            if not MENTIONED.fullmatch(name):
                continue
            if named and Path(name).name not in named:
                continue
            now = git(repo, 'rev-parse', '--verify', '--quiet', '%s:%s' % (base, name), check=False)
            before = git(repo, 'rev-parse', '--verify', '--quiet', '%s^:%s' % (commit, name), check=False)
            if now.returncode != 0 or before.returncode != 0:
                continue
            if now.stdout.strip() == before.stdout.strip():
                problems.append('%s: %s is back at its pre-fix blob' % (where, name))
    return {'findings': findings, 'skipped': skipped, 'problems': problems}


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo-root', default='.')
    parser.add_argument('--findings', default='docs/laa/findings')
    parser.add_argument('--base', default='master')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args(argv)

    repo = Path(args.repo_root)
    findings_dir = repo / args.findings
    if not findings_dir.is_dir():
        print('error: no findings directory at %s' % findings_dir, file=sys.stderr)
        return 2
    try:
        report = judge(repo, findings_dir, args.base)
    except RuntimeError as error:
        print('error: %s' % error, file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(report, ensure_ascii=False))
    elif report['problems']:
        for problem in report['problems']:
            print('error: ' + problem)
        print('%d fixed row(s) judged, %d sha(s) not in this repo' % (report['findings'], report['skipped']))
    else:
        print('%d fixed row(s) judged, %d sha(s) not in this repo, all still true'
              % (report['findings'], report['skipped']))
    return 1 if report['problems'] else 0


if __name__ == '__main__':
    sys.exit(main())
