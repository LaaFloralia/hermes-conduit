"""Regression coverage for scripts/laa/check-findings-fixes.py."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from _util import load_module

check = load_module('check_findings_fixes', 'laa/check-findings-fixes.py')

ROW = '| 2026-11-28 | Work › Tasks batch bar | A pill. | `LAATaskRows.swift` line 106 | P2 | %s |\n'
ELSEWHERE = '| 2026-11-28 | Work › Tasks batch bar | A pill. | `Other.swift` line 106 | P2 | fixed %s |\n'
HEADER = '| date | screen/area | finding | evidence | weight | status |\n|---|---|---|---|---|---|\n'


def git(repo, *args):
    env = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t',
               GIT_COMMITTER_EMAIL='t@t')
    return subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True, text=True,
                          env=env).stdout.strip()


def commit(repo, message, files):
    for name, body in files.items():
        path = Path(repo) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding='utf-8')
    git(repo, 'add', '-A')
    git(repo, 'commit', '-q', '-m', message)
    return git(repo, 'rev-parse', 'HEAD')


class CheckFindingsFixesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / 'repo'
        self.repo.mkdir()
        git(self.repo, 'init', '-q', '-b', 'master')
        self.findings = 'docs/laa/findings/2026-11-iphone.md'
        commit(self.repo, 'base', {'Conduit/LAATaskRows.swift': 'in: Capsule()\n',
                                   self.findings: HEADER + ROW % 'open'})

    def tearDown(self):
        self.tmp.cleanup()

    def write_status(self, status):
        commit(self.repo, 'row', {self.findings: HEADER + ROW % status})

    def run_check(self):
        return check.main(['--repo-root', str(self.repo), '--findings', 'docs/laa/findings',
                           '--json'])

    def test_a_fix_still_on_master_passes(self):
        fix = commit(self.repo, 'fix', {'Conduit/LAATaskRows.swift': 'in: RoundedRectangle()\n'})
        self.write_status('fixed %s' % fix[:9])
        self.assertEqual(self.run_check(), 0)

    def test_a_file_back_at_its_pre_fix_blob_fails(self):
        fix = commit(self.repo, 'fix', {'Conduit/LAATaskRows.swift': 'in: RoundedRectangle()\n'})
        self.write_status('fixed %s' % fix[:9])
        commit(self.repo, 'keep it out of this pass', {'Conduit/LAATaskRows.swift': 'in: Capsule()\n'})
        report = check.judge(self.repo, self.repo / 'docs/laa/findings')
        self.assertEqual(len(report['problems']), 1)
        self.assertIn('Conduit/LAATaskRows.swift is back at its pre-fix blob', report['problems'][0])
        self.assertEqual(self.run_check(), 1)

    def test_a_reverted_file_with_its_row_moved_to_open_passes(self):
        fix = commit(self.repo, 'fix', {'Conduit/LAATaskRows.swift': 'in: RoundedRectangle()\n'})
        self.write_status('fixed %s' % fix[:9])
        commit(self.repo, 'revert and say so',
               {'Conduit/LAATaskRows.swift': 'in: Capsule()\n', self.findings: HEADER + ROW % 'open'})
        self.assertEqual(self.run_check(), 0)

    def test_a_row_is_judged_on_the_file_it_names(self):
        fix = commit(self.repo, 'fix', {'Conduit/LAATaskRows.swift': 'in: RoundedRectangle()\n',
                                        'Conduit/Other.swift': 'let a = 1\n'})
        commit(self.repo, 'revert one of the two',
               {'Conduit/LAATaskRows.swift': 'in: Capsule()\n',
                self.findings: HEADER + ELSEWHERE % fix[:9]})
        self.assertEqual(self.run_check(), 0)
        commit(self.repo, 'name the reverted one too',
               {self.findings: HEADER + ELSEWHERE % fix[:9] + ROW % ('fixed %s' % fix[:9])})
        self.assertEqual(self.run_check(), 1)

    def test_a_sha_from_another_repo_is_skipped(self):
        self.write_status('fixed 0123456789abcdef')
        report = check.judge(self.repo, self.repo / 'docs/laa/findings')
        self.assertEqual((report['findings'], report['skipped'], report['problems']), (0, 1, []))


if __name__ == '__main__':
    unittest.main()
