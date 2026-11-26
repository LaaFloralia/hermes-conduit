#!/usr/bin/env python3
"""The routine-delivery installer routes staff reports to the shared room on a
Hermes without native chat-note support (no gateway.session_cron), and keeps
other report-only jobs from starting an AI turn. Synthetic plugin text only."""
import functools
import importlib.util
import logging
import tempfile
import threading
import types
import unittest
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('install_routine_delivery', ROOT / 'scripts/laa/install-routine-delivery.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

# The reviewed upstream shape of the hooks the installer edits.
CHAT = '''
def show(job, content, profile, *, for_failure=False):
    target = f"bot-chat:{profile or '(own)'}"
    return target


def _replacement(original: Callable[..., Any]) -> Callable[..., Any]:
    def _deliver_to_bot_chat(job: dict, content: str, profile: str, *args: Any, **kwargs: Any) -> Any:
        if lets_act(job):
            return original(job, content, profile, *args, **kwargs)
        # Hermes passes it by keyword; positionally, it's the next one.
        for_failure = kwargs.get("for_failure", args[0] if args else False)
        return show(job, content, profile, for_failure=bool(for_failure))

    functools.update_wrapper(_deliver_to_bot_chat, original)
    setattr(_deliver_to_bot_chat, _GUARD_FLAG, True)
    return _deliver_to_bot_chat


def supported() -> bool:
    return native_note_support()


def install() -> bool:
    global _installed
    with _lock:
        if _installed is not None:
            return True
        own = getattr(_delivery_module(), METHOD, None)
        if not callable(own) or not supported():
            return False
        replacement = _replacement(own)
        setattr(_delivery_module(), METHOD, replacement)
        _installed = replacement
        return True
'''
RUNS = '''
def quiet(job, response=None):
    return muted(job) or (response is not None and is_silent(response))
'''


class InstallRoutineDeliveryTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__('shutil').rmtree(self.dir))
        (self.dir / 'cron_bot_chat.py').write_text(CHAT)
        (self.dir / 'cron_runs.py').write_text(RUNS)
        self.source = ROOT / 'bridge/src/routines/delivery.py'

    def patched(self, *, native):
        installer.install(self.dir, self.source, apply=True)
        calls = []
        scheduler = types.SimpleNamespace(_deliver_to_bot_chat=lambda *a, **k: calls.append('bot-turn'))
        package = types.ModuleType('fixture_plugin')
        package.routine_delivery = types.SimpleNamespace(handles=lambda profile: profile == 'laa-monet')
        env = {'__name__': 'fixture_plugin.cron_bot_chat', '__package__': 'fixture_plugin',
               'Callable': Callable, 'Any': Any, 'functools': functools, '_lock': threading.Lock(),
               '_installed': None, '_delivery_module': lambda: scheduler, 'METHOD': '_deliver_to_bot_chat',
               '_GUARD_FLAG': '__guard__', 'logger': logging.getLogger('fixture'),
               'native_note_support': lambda: native, 'lets_act': lambda job: job.get('act', False)}
        import sys
        sys.modules['fixture_plugin'] = package
        self.addCleanup(sys.modules.pop, 'fixture_plugin', None)
        exec(compile((self.dir / 'cron_bot_chat.py').read_text(), 'cron_bot_chat.py', 'exec'), env)
        env['show'] = lambda *a, **k: calls.append('group-report')
        self.assertTrue(env['install']())
        return scheduler, calls

    def test_staff_report_reaches_the_room_without_native_note_support(self):
        scheduler, calls = self.patched(native=False)
        self.assertIsNone(scheduler._deliver_to_bot_chat({'act': True}, 'report', 'laa-monet'))
        self.assertEqual(calls, ['group-report'])

    def test_other_report_only_job_fails_closed_without_native_note_support(self):
        scheduler, calls = self.patched(native=False)
        error = scheduler._deliver_to_bot_chat({'act': False}, 'report', 'other')
        self.assertEqual(calls, [])
        self.assertIn('no AI turn', error)

    def test_explicit_act_job_still_starts_its_turn(self):
        scheduler, calls = self.patched(native=False)
        scheduler._deliver_to_bot_chat({'act': True}, 'report', 'other')
        self.assertEqual(calls, ['bot-turn'])

    def test_native_note_support_keeps_report_only_notes(self):
        scheduler, calls = self.patched(native=True)
        scheduler._deliver_to_bot_chat({'act': False}, 'report', 'other')
        self.assertEqual(calls, ['group-report'])

    def test_reapplying_is_a_no_op(self):
        installer.install(self.dir, self.source, apply=True)
        first = (self.dir / 'cron_bot_chat.py').read_text(), (self.dir / 'cron_runs.py').read_text()
        installer.install(self.dir, self.source, apply=True)
        self.assertEqual(first, ((self.dir / 'cron_bot_chat.py').read_text(), (self.dir / 'cron_runs.py').read_text()))

    def test_unreviewed_upstream_shape_stops(self):
        (self.dir / 'cron_bot_chat.py').write_text(CHAT.replace('or not supported()', 'or not ready()'))
        with self.assertRaises(ValueError):
            installer.install(self.dir, self.source)


if __name__ == '__main__':
    unittest.main()
