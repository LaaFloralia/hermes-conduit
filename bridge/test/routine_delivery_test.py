"""Staff-chat delivery and the repeated-failure rule, on a real receipt database."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('routine_delivery', Path(__file__).parents[1] / 'src/routines/delivery.py')
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)


class RoutineDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.sent, self.notes, self.fixes = [], [], []
        self.clock = 1000.0

    def tearDown(self):
        self.temp.cleanup()

    def fix(self, profile, job, signature, content):
        self.fixes.append((profile, job['id'], signature))
        return 'BUS-900'

    def report(self, run='run-1', text='result', profile='laa-cos', job='job-a', muted=False, for_failure=False):
        def write_note(body, key):
            self.notes.append((profile, body, key))
            return f'chat-{profile}'
        self.clock += 60
        return delivery.store_report({'id': job, 'name': 'Daily', 'execution_id': run}, text, profile,
                                     write_note=write_note, send=self.sent.append,
                                     receipt_path=self.root / 'n.db', muted=muted, for_failure=for_failure,
                                     fix=self.fix, now=lambda: self.clock)

    def test_report_goes_to_the_staff_members_own_chat(self):
        receipt = self.report(profile='laa-cfo')
        self.assertEqual(receipt['destination'], 'bot-chat:laa-cfo')
        self.assertEqual(self.notes[0][0], 'laa-cfo')
        self.assertEqual(self.sent[0]['session_id'], 'chat-laa-cfo')
        self.assertEqual(self.sent[0]['profile'], 'laa-cfo')
        self.assertTrue(self.sent[0]['title'].startswith('Morgan'))

    def test_retry_is_one_push_and_keeps_the_decision(self):
        self.report(text='障害: chrome_profile_access_denied', run='r1')
        self.report(text='障害: chrome_profile_access_denied', run='r1')
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.fixes, [])

    def test_second_identical_failure_opens_a_fix_then_silence_then_recovery(self):
        fail = '障害: Chromeのデータを読めない（chrome_profile_access_denied）'
        first = self.report(run='r1', text=fail)
        self.assertEqual(first['outcome'], 'failure')
        second = self.report(run='r2', text=fail + ' 13:00')
        self.assertEqual(second['outcome'], 'fix_opened')
        self.assertIn('BUS-900', self.notes[-1][1])
        self.assertEqual(len(self.fixes), 1)
        third = self.report(run='r3', text=fail)
        self.assertEqual(third['status'], 'suppressed')
        self.assertEqual(len(self.sent), 2)
        ok = self.report(run='r4', text='新着なし')
        self.assertEqual(ok['outcome'], 'recovered')
        self.assertTrue(self.notes[-1][1].startswith('直りました（BUS-900）'))
        self.assertEqual(len(self.fixes), 1)

    def test_different_failure_starts_over(self):
        self.report(run='r1', text='障害: signed_out')
        self.assertEqual(self.report(run='r2', text='障害: chrome_unavailable')['outcome'], 'failure')
        self.assertEqual(self.fixes, [])

    def test_runtime_failure_counts_and_normal_text_does_not(self):
        self.assertIsNone(delivery.failure_signature('告。新着2件'))
        self.assertEqual(delivery.failure_signature('[CRON_FAILURE]\nscript_timeout after 180s'), 'script_timeout')
        self.assertIsNotNone(delivery.failure_signature('Job timed out', for_failure=True))
        self.assertEqual(delivery.failure_signature('障害: 画面を読めない（WINDOW_UNREADABLE／HTTP_503）'), 'WINDOW_UNREADABLE')

    def test_muted_job_stores_without_push(self):
        self.assertEqual(self.report(muted=True)['notification_status'], 'muted')
        self.assertEqual(self.sent, [])

    def test_digest_has_one_entry_per_staff(self):
        self.report(run='a', profile='laa-cos')
        self.report(run='b', profile='laa-cos', job='job-b', text='障害: signed_out')
        self.report(run='c', profile='laa-cso')
        staff = delivery.digest(self.root / 'n.db', 0)
        self.assertEqual(staff['laa-cos']['runs'], 2)
        self.assertEqual(staff['laa-cos']['failures'][0]['signature'], 'signed_out')
        self.assertEqual(staff['laa-cso']['runs'], 1)

    def test_work_run_model_lands_on_the_hermes_run_once(self):
        runs, home = self.root / 'run', self.root / 'home'
        runs.mkdir(); (home / 'cron').mkdir(parents=True)
        (runs / 'job-a.json').write_text(json.dumps({'at': 990.0, 'model': 'gpt-6.2-sol', 'provider': 'codex',
                                                     'effort': 'high', 'verified': True, 'requestId': 'r1'}))
        job = {'id': 'job-a', 'execution_id': 'e1', 'deliver': 'bot-chat:laa-cos'}
        line = delivery.record_work_run(home, job, runs=runs, now=lambda: 1000.0)
        self.assertEqual((line['execution_id'], line['model'], line['reasoning_effort']), ('e1', 'gpt-6.2-sol', 'high'))
        self.assertIsNone(delivery.record_work_run(home, {**job, 'execution_id': 'e2'}, runs=runs, now=lambda: 1000.0))
        self.assertEqual(len((home / 'cron/usage_audit.jsonl').read_text().splitlines()), 1)

    def test_stale_work_run_is_not_claimed(self):
        runs = self.root / 'run'; runs.mkdir()
        (runs / 'job-a.json').write_text(json.dumps({'at': 0.0, 'model': 'x'}))
        self.assertIsNone(delivery.record_work_run(self.root, {'id': 'job-a', 'execution_id': 'e1'}, runs=runs, now=lambda: 5000.0))

    def test_unknown_profile_is_refused(self):
        with self.assertRaises(ValueError):
            self.report(profile='laa-soap')

    def test_schema_is_readable_by_plain_sqlite(self):
        self.report()
        with sqlite3.connect(self.root / 'n.db') as db:
            self.assertEqual(db.execute('SELECT outcome FROM routine_reports').fetchone()[0], 'shown')


if __name__ == '__main__':
    unittest.main()
