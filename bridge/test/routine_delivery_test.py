"""Exercise the real hosted-room store across process/reopen boundaries."""
import concurrent.futures
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import types
import builtins
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('routine_delivery', Path(__file__).parents[1] / 'src/routines/delivery.py')
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)
delivery.bootstrap()
from gateway import hosted_rooms


class RoutineDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.sent = []

    def tearDown(self):
        self.temp.cleanup()

    def report(self, run='run-1', text='result', profile='laa-monet', runner='hermes', send=None, muted=False):
        job = {'id': 'job-a', 'name': 'Daily', 'execution_id': run, 'routine_runner': runner}
        return delivery.store_report(job, text, profile, rooms=hosted_rooms,
            db_path=self.root / 'shared-state.db', authority='install:fixture', model='model-test',
            redact=lambda text, label: text.replace('SECRET', '[redacted]'),
            receipt_path=self.root / 'notifications.db', send=send or self.sent.append, muted=muted)

    def test_reopen_replays_the_same_report_and_tap_identity(self):
        result = self.report(text='SECRET')
        # Fresh connection, exactly what groups.log uses after the app restarts.
        page = hosted_rooms.read_events(self.root / 'shared-state.db', room_id=delivery.ROOM_ID, since_seq=0)
        self.assertEqual(len(page['events']), 1)
        self.assertIn('[redacted]', page['events'][0]['payload']['text'])
        self.assertNotIn('SECRET', str(page))
        self.assertEqual(self.sent[0]['room'], {'id': delivery.ROOM_ID})
        self.assertEqual(self.sent[0]['session_id'], f"laa-routine:laa-routines:{result['seq']}:{result['event_id']}")

    def test_retry_is_one_message_and_one_push(self):
        self.assertEqual(self.report(), self.report())
        self.assertEqual(len(self.sent), 1)

    def test_conflicting_retry_is_rejected(self):
        self.report()
        with self.assertRaises(hosted_rooms.EventConflictError):
            self.report(text='different')
        self.assertEqual(len(self.sent), 1)

    def test_all_workers_and_owners_share_one_room(self):
        for profile in delivery.STAFF:
            for runner in ('hermes', 'dots', 'muse', 'work'):
                self.report(run=runner, profile=profile, runner=runner)
        with sqlite3.connect(self.root / 'shared-state.db') as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM hosted_rooms').fetchone()[0], 1)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM hosted_room_events').fetchone()[0], 20)
        self.assertEqual(list(self.root.glob('*/state.db')), [])

    def test_failed_push_keeps_report_and_retry_finishes_it(self):
        def fail(event): raise ConnectionError()
        with self.assertRaises(ConnectionError):
            self.report(send=fail)
        self.report()
        self.assertEqual(len(self.sent), 1)
        with sqlite3.connect(self.root / 'shared-state.db') as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM hosted_room_events').fetchone()[0], 1)

    def test_parallel_retries_never_duplicate(self):
        self.report()
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _: self.report(), range(12)))
        self.assertEqual(len(self.sent), 1)

    def test_missing_run_id_never_writes(self):
        with self.assertRaises(ValueError): self.report(run=None)
        self.assertFalse((self.root / 'shared-state.db').exists())

    def test_muted_report_remains_in_the_room(self):
        result = self.report(muted=True)
        self.assertEqual(result['notification_status'], 'muted')
        self.assertEqual(self.report()['notification_status'], 'muted')
        self.assertEqual(self.sent, [])
        self.assertTrue((self.root / 'shared-state.db').exists())

    def test_gateway_plugin_namespace_does_not_require_bare_package_import(self):
        # Hermes loads directory plugins under hermes_plugins.<slug>, not
        # importable as bare conduit_push. The CLI bootstrap masks this gap.
        namespace = 'hermes_plugins.routine_delivery_probe'
        parent = sys.modules.setdefault('hermes_plugins', types.ModuleType('hermes_plugins'))
        if not hasattr(parent, '__path__'): parent.__path__ = []
        package = types.ModuleType(namespace)
        package.__path__ = [str(Path.home() / '.hermes/plugins/conduit_push')]
        package.__package__ = namespace
        sys.modules[namespace] = package
        spec = importlib.util.spec_from_file_location(namespace + '.routine_delivery', Path(delivery.__file__))
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        store_module = importlib.import_module(namespace + '.cron_store')
        real_import = builtins.__import__
        def gateway_import(name, *args, **kwargs):
            if name == 'conduit_push' or name.startswith('conduit_push.'):
                raise ModuleNotFoundError("No module named 'conduit_push'", name='conduit_push')
            return real_import(name, *args, **kwargs)
        with patch('builtins.__import__', side_effect=gateway_import), \
             patch.object(module, 'store_report') as store, \
             patch.object(store_module, 'CronStore'):
            error = module.show({'id': 'namespace-test', 'execution_id': 'run-a', 'model': 'model-test'},
                                'Gateway report', 'laa-monet')
            self.assertIsNone(error)
            store.assert_called_once()
        for name in list(sys.modules):
            if name == namespace or name.startswith(namespace + '.'):
                sys.modules.pop(name, None)

    def test_work_retry_freezes_run_identity_and_catches_autoarchived_run_once(self):
        jobs = self.root / 'jobs.json'
        state = self.root / 'watcher.json'
        state.write_text(json.dumps({'since': 0}))
        job = {'id': 'a', 'name': 'Original', 'target': {'config': {'model': 'model-a'}},
            'runs': [{'id': 'run-a', 'status': 'succeeded', 'endedAt': '2026-11-16T00:00:00Z', 'output': 'report'}]}
        jobs.write_text(json.dumps([job]))
        with patch.object(delivery, 'show', side_effect=['push pending', None]) as show:
            self.assertEqual(len(delivery.scan_work(jobs, state)['errors']), 1)
            job['name'] = 'Renamed'
            job['target']['config']['model'] = 'model-b'
            jobs.write_text(json.dumps([job]))
            self.assertEqual(delivery.scan_work(jobs, state)['errors'], [])
            self.assertEqual(delivery.scan_work(jobs, state)['errors'], [])
            self.assertEqual(show.call_count, 2)
            self.assertEqual(show.call_args_list[0].args[0], show.call_args_list[1].args[0])


if __name__ == '__main__': unittest.main()
