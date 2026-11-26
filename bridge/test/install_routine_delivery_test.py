#!/usr/bin/env python3
"""Installer checks; CONDUIT_NOTIFIER_GIT points to a local upstream Git clone.

Use the reviewed Git blobs, never the deployed plugin or a network download.
"""
import importlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/laa/install-routine-delivery.py'
spec = importlib.util.spec_from_file_location('install_routine_delivery', SCRIPT)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

UPSTREAM = os.environ.get('CONDUIT_NOTIFIER_GIT')
REVISIONS = ('2b947ecd6fe4db73e369577cc2d59c4ca0b707d0',
             '6f39468223dc48d6c3562efc20cd9ec430c8c190')
BLOBS = ('cron_bot_chat.py', 'cron_runs.py', 'cron_store.py', 'events.py', 'plugin.yaml',
         'dashboard/api/notifications.py')


class InstallRoutineDeliveryTest(unittest.TestCase):
    def test_recognized_one_match_and_true_no_op(self):
        result = installer.replace_once('old', 'hook', ('old', 'older'), 'new old')
        self.assertEqual(result, 'new old')
        self.assertIs(installer.replace_once(result, 'hook', 'old', result), result)

    def test_unknown_duplicate_and_mixed_anchors_stop(self):
        for bad in ('unknown', 'old old', 'patched old', 'patched patched'):
            with self.subTest(bad=bad), self.assertRaisesRegex(ValueError, 'hook'):
                installer.replace_once(bad, 'hook', 'old', 'patched')

    @unittest.skipUnless(UPSTREAM, 'set CONDUIT_NOTIFIER_GIT for the reviewed two-revision integration gate')
    def test_reviewed_revisions(self):
        for revision in REVISIONS:
            with self.subTest(revision=revision), tempfile.TemporaryDirectory() as temp:
                plugin = Path(temp) / 'conduit_push'
                for name in BLOBS:
                    target = plugin / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(subprocess.check_output(['git', '-C', UPSTREAM, 'show', f'{revision}:{name}']))
                self.check_install(plugin)
                self.check_gateway_namespace(plugin, current=revision == REVISIONS[1])

    def check_install(self, plugin):
        def snapshot():
            return {p.relative_to(plugin): (p.read_bytes(), p.stat().st_mtime_ns)
                    for p in plugin.rglob('*.py')}

        original = snapshot()
        command = [sys.executable, '-B', str(SCRIPT), '--plugin', str(plugin)]
        subprocess.run(command, check=True, capture_output=True)
        self.assertEqual(snapshot(), original)
        # A late mismatch must not write even the previously validated files.
        dashboard = plugin / 'dashboard/api/notifications.py'
        original_dashboard = dashboard.read_text()
        dashboard.write_text(original_dashboard.replace('cron = importlib.import_module', 'cron = something_else'))
        broken = snapshot()
        result = subprocess.run(command + ['--apply'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('dashboard/api/notifications.py: capability probe', result.stderr)
        self.assertEqual(snapshot(), broken)
        dashboard.write_text(original_dashboard)

        subprocess.run(command + ['--apply'], check=True, capture_output=True)
        installed = snapshot()
        self.assertEqual((plugin / 'cron_note_compat.py').read_bytes(),
                         (installer.SOURCE / 'cron_note_compat.py').read_bytes())
        self.assertNotEqual(installed, original)
        self.assertEqual(installer.install(plugin, apply=True)['changed'], [])
        self.assertEqual(snapshot(), installed)

    def check_gateway_namespace(self, plugin, *, current):
        namespace = 'hermes_plugins.conduit_push'
        parent = types.ModuleType('hermes_plugins')
        parent.__path__ = [str(plugin.parent)]
        package = types.ModuleType(namespace)
        package.__path__ = [str(plugin)]
        constants = types.ModuleType('hermes_constants')
        constants.get_hermes_home = lambda: plugin.parent
        modules = {'hermes_plugins': parent, namespace: package, 'conduit_push': None,
                   'hermes_constants': constants}
        with patch.dict(sys.modules, modules):
            chat = importlib.import_module(namespace + '.cron_bot_chat')
            adapter = importlib.import_module(namespace + '.cron_note_compat')
            delivery = importlib.import_module(namespace + '.routine_delivery')
            runs = importlib.import_module(namespace + '.cron_runs')
            original = Mock(return_value='original')
            scheduler = types.SimpleNamespace(_deliver_to_bot_chat=original)
            try:
                with patch.object(chat, '_delivery_module', return_value=scheduler), \
                     patch.object(chat, '_native_supported', return_value=False), \
                     patch.object(adapter, 'supported', return_value=True) as supported, \
                     patch.object(chat, 'lets_act', return_value=True) as act, \
                     patch.object(delivery, 'show', return_value=None) as show:
                    self.assertTrue(chat.install())
                    wrapped = scheduler._deliver_to_bot_chat
                    job = {'id': 'routine', 'execution_id': 'run'}
                    self.assertIsNone(wrapped(job, 'report', 'laa-cfo', True))
                    show.assert_called_once_with(job, 'report', 'laa-cfo', for_failure=True)
                    original.assert_not_called()
                    self.assertEqual(wrapped(job, 'report', 'other'), 'original')
                    original.assert_called_once()
                    original.reset_mock()
                    act.return_value = False
                    supported.return_value = False
                    self.assertIn('no AI turn', wrapped(job, 'report', 'other'))
                    original.assert_not_called()
                    supported.return_value = True
                    with patch.object(chat, 'show', return_value=None) as note:
                        self.assertIsNone(wrapped(job, 'report', 'other'))
                        note.assert_called_once_with(job, 'report', 'other', for_failure=False)
                with patch.object(runs, 'muted', return_value=False), \
                     patch.object(delivery, 'quiets', return_value=True) as quiets:
                    if current:
                        self.assertFalse(runs.quiet('cron_routine', 'cron:routine:run'))
                        self.assertTrue(runs.quiet('cron_routine', 'cron:routine:run', delivered=True, failure=True))
                        quiets.assert_called_once_with('routine', for_failure=True)
                    else:
                        self.assertTrue(runs.quiet('cron_routine', 'cron:routine:run'))
                        quiets.assert_called_once_with('routine')
            finally:
                chat.uninstall()
            self.assertIs(scheduler._deliver_to_bot_chat, original)


if __name__ == '__main__':
    unittest.main()
