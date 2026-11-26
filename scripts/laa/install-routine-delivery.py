#!/usr/bin/env python3
"""Install the LAA report-only overlay without replacing the upstream checkout."""
import argparse
import json
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[2] / 'bridge/src/routines'


def replace_once(text, label, before, after):
    """Match exactly one reviewed form, including the already-installed one."""
    upstream = (before,) if isinstance(before, str) else before
    # Some replacements contain the original anchor as a suffix.
    installed = text.count(after)
    remainder = text.replace(after, '')
    matches = [(anchor, remainder.count(anchor)) for anchor in upstream]
    if installed == 1 and not any(count for _, count in matches):
        return text
    if installed == 0 and sum(count for _, count in matches) == 1:
        anchor = next(anchor for anchor, count in matches if count)
        return text.replace(anchor, after, 1)
    raise ValueError(f'{label}: no unique reviewed compatibility hook')


TARGET = '    target = f"bot-chat:{profile or \'(own)\'}"\n'
SHOW = '''    from . import routine_delivery
    if routine_delivery.handles(profile):
        return routine_delivery.show(job, content, profile, for_failure=for_failure)
''' + TARGET
ARGS = '''        # Hermes passes it by keyword; positionally, it's the next one.
        for_failure = kwargs.get("for_failure", args[0] if args else False)
'''
ACT_183 = '''        if lets_act(job):
            return original(job, content, profile, *args, **kwargs)
'''
ACT_CURRENT = '''        if lets_act(job):
            result = original(job, content, profile, *args, **kwargs)
            _acted(job, content, profile, result, for_failure)
            return result
'''
UNAVAILABLE = '''        if not supported():
            return "bot-chat report-only storage unavailable; no AI turn"
'''
LEGACY_DISPATCH = '''        from . import routine_delivery
        if routine_delivery.handles(profile):
            return show(job, content, profile, for_failure=bool(kwargs.get("for_failure", args[0] if args else False)))
'''
SHOW_REPORT = '        return show(job, content, profile, for_failure=for_failure)\n'

INSTALL_CHECK = '''        if not callable(own) or not supported():
            logger.info("conduit_push: this Hermes can't show a cron report in a Bot Chat without a turn; "
                        "jobs delivered to a Bot Chat start the bot's turn")
            return False
'''


def patch_chat(text):
    def replace(label, before, after):
        nonlocal text
        text = replace_once(text, f'cron_bot_chat.py: {label}', before, after)

    replace('module description', 'without the local-chat note keeps its own delivery for every job.',
            'without the local-chat note uses the guarded state-store adapter.')
    replace('staff report route', TARGET, SHOW)
    replace('Bot Chat lookup', '''    from tools.bot_live_delivery import _bot_chat_tip

    return _bot_chat_tip(home)
''', '''    from . import cron_note_compat

    if _native_supported():
        from tools.bot_live_delivery import _bot_chat_tip

        return _bot_chat_tip(home)
    return cron_note_compat.bot_chat_tip(home)
''')
    replace('note write', '''            db.append_completion_note(chat, key, text, "internal_notification", metadata)
            return None
''', '''            from .cron_note_compat import write_note

            write_note(db, chat, key, text, metadata)
            return None
        except ValueError as exc:
            return f"bot-chat report not written: {exc!r}"
''')
    replace('native note owner', '    return importlib.import_module(LOCAL_NOTE).owner_for_home(home) is not None\n',
            '''    return _native_supported() and importlib.import_module(LOCAL_NOTE).owner_for_home(home) is not None
''')
    native = '''    from . import hermes_store

    try:
        cron = importlib.import_module(LOCAL_NOTE)
    except Exception:  # noqa: BLE001
        return False
    return (callable(getattr(cron, "deliver_to_local_chat", None))
            and callable(getattr(cron, "owner_for_home", None))
            and hermes_store.can("append_completion_note"))
'''
    probe = '''def supported() -> bool:
    """Whether this Hermes can write a cron result into a chat as a note."""
'''
    replace('capability probe', probe + native, probe + '''    from . import cron_note_compat

    return _native_supported() or cron_note_compat.supported()


def _native_supported() -> bool:
''' + native)
    # Keep the newer upstream's explicit-act push handling. Report-only
    # routes, and all named staff routes, must never start an upstream turn.
    staff = '''        from . import routine_delivery

        if routine_delivery.handles(profile):
            return show(job, content, profile, for_failure=for_failure)
'''
    old_dispatch = ACT_183 + ARGS + SHOW_REPORT.replace('=for_failure)', '=bool(for_failure))')
    current_dispatch = ARGS.replace('= kwargs.get("for_failure", args[0] if args else False)',
                                    '= bool(kwargs.get("for_failure", args[0] if args else False))')
    if ACT_CURRENT in text:
        replace('report/act dispatcher', current_dispatch + ACT_CURRENT + SHOW_REPORT,
                current_dispatch + staff + ACT_CURRENT + UNAVAILABLE + SHOW_REPORT)
    else:
        replace('report/act dispatcher', (old_dispatch, LEGACY_DISPATCH + ACT_183 + UNAVAILABLE + ARGS
                                           + SHOW_REPORT.replace('=for_failure)', '=bool(for_failure))')),
                current_dispatch + staff + ACT_183 + UNAVAILABLE + SHOW_REPORT)
    replace('install description', '''    process. False when this Hermes has no Bot Chat delivery or can't write
    a note, and every job then keeps Hermes' turn."""''', '''    process. False only when this Hermes has no Bot Chat delivery. Without
    note storage, reports fail closed instead of starting a turn."""''')
    replace('install guard', (INSTALL_CHECK, INSTALL_CHECK.replace(' or not supported()', '')), '''        if not callable(own):
            return False
        if not supported():
            logger.warning("conduit_push: report-only storage unavailable; reports stay in run history")
''')
    return text


def patch_runs(text):
    muted = 'muted(job) or (response is not None and is_silent(response))'
    old = f'    return {muted}\n'
    old_overlay = f'    from . import routine_delivery\n    return routine_delivery.quiets(job) or {muted}\n'
    current = (f'    if {muted}:\n        return True\n'
               '    if not delivered or job_id(None, task_id) is None:\n        return False\n')
    guard = '    job = job_id(session_id, task_id)\n    if job is None:\n        return False\n'
    if '          delivered: bool = False, failure: bool = False) -> bool:\n' in text:
        before = (current,)
        after = current + '''    from . import routine_delivery

    if routine_delivery.quiets(job, for_failure=failure):
        return True
'''
    else:
        before = (old, old_overlay)
        after = f'    from . import routine_delivery\n\n    return routine_delivery.quiets(job) or {muted}\n'
    return replace_once(text, 'cron_runs.py: quiet', tuple(guard + anchor for anchor in before), guard + after)


def patch_dashboard(text):
    text = replace_once(text, 'dashboard/api/notifications.py: capability description', '''    can't import the plugin package). Without it every job keeps Hermes'
    turn, and Conduit offers no choice.''', '''    can't import the plugin package). A report without storage must never
    start a turn as a fallback.''')
    return replace_once(text, 'dashboard/api/notifications.py: capability probe', '''            import importlib

            cron = importlib.import_module("gateway.session_cron")
            _shows_reports = (callable(getattr(cron, "deliver_to_local_chat", None))
                              and callable(getattr(cron, "owner_for_home", None))
                              and core._hermes_store().can("append_completion_note"))
''', '''            try:
                cron = importlib.import_module("gateway.session_cron")
            except ImportError:
                cron = None
            native = (callable(getattr(cron, "deliver_to_local_chat", None))
                      and callable(getattr(cron, "owner_for_home", None))
                      and core._hermes_store().can("append_completion_note"))
            if native:
                _shows_reports = True
            else:
                # Dashboard plugins are loaded by path, not as agent plugins.
                path = os.path.join(core._plugin_root(), "cron_note_compat.py")
                spec = importlib.util.spec_from_file_location("conduit_cron_note_compat", path)
                if spec is None or spec.loader is None:
                    raise ImportError("cron_note_compat is unavailable")
                compat = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(compat)
                _shows_reports = compat.supported()
''')


def install(plugin, source=SOURCE, *, apply=False):
    changes = {}
    for name, source_name in [('cron_note_compat.py', 'cron_note_compat.py'), ('routine_delivery.py', 'delivery.py')]:
        changes[plugin / name] = (source / source_name).read_text(encoding='utf-8')
    for name, patch in [('cron_bot_chat.py', patch_chat), ('cron_runs.py', patch_runs),
                        ('dashboard/api/notifications.py', patch_dashboard)]:
        path = plugin / name
        changes[path] = patch(path.read_text(encoding='utf-8'))
    # Check every anchor and syntax before writing any file, including assets.
    for path, text in changes.items():
        compile(text, str(path), 'exec')
    changed = {path: text for path, text in changes.items()
               if not path.exists() or path.read_bytes() != text.encode('utf-8')}
    if apply:
        for path, text in changed.items():
            path.write_text(text, encoding='utf-8')
    return {'applied': apply, 'files': [str(path.relative_to(plugin)) for path in changes],
            'changed': [str(path.relative_to(plugin)) for path in changed]}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plugin', type=Path, default=Path.home() / '.hermes/plugins/conduit_push')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(install(args.plugin, apply=args.apply)))
    except (OSError, ValueError, SyntaxError) as exc:
        parser.exit(1, f'{exc}\n')
