#!/usr/bin/env python3
"""Deploy only the LAA cron compatibility hooks; preserve the upstream checkout."""
from pathlib import Path
import argparse
import shutil


def replace_once(text, before, after):
    if after in text:
        return text
    if text.count(before) != 1:
        raise ValueError('Installed plugin no longer matches the reviewed compatibility hook')
    return text.replace(before, after, 1)


def install(plugin, source, *, apply=False):
    chat = plugin / 'cron_bot_chat.py'
    runs = plugin / 'cron_runs.py'
    chat_text = chat.read_text()
    chat_text = replace_once(chat_text,
        '    target = f"bot-chat:{profile or \'(own)\'}"\n',
        '    from . import routine_delivery\n'
        '    if routine_delivery.handles(profile):\n'
        '        return routine_delivery.show(job, content, profile, for_failure=for_failure)\n'
        '    target = f"bot-chat:{profile or \'(own)\'}"\n')
    chat_text = replace_once(chat_text,
        '        if lets_act(job):\n',
        '        from . import routine_delivery\n'
        '        if routine_delivery.handles(profile):\n'
        '            return show(job, content, profile, for_failure=bool(kwargs.get("for_failure", args[0] if args else False)))\n'
        '        if lets_act(job):\n')
    runs_text = replace_once(runs.read_text(),
        '    return muted(job) or (response is not None and is_silent(response))\n',
        '    from . import routine_delivery\n'
        '    return routine_delivery.quiets(job) or muted(job) or (response is not None and is_silent(response))\n')
    compile(chat_text, str(chat), 'exec')
    compile(runs_text, str(runs), 'exec')
    compile(source.read_text(), str(source), 'exec')
    if apply:
        shutil.copyfile(source, plugin / 'routine_delivery.py')
        chat.write_text(chat_text)
        runs.write_text(runs_text)
    return {'applied': apply, 'files': ['routine_delivery.py', 'cron_bot_chat.py', 'cron_runs.py']}


if __name__ == '__main__':
    import json
    parser = argparse.ArgumentParser()
    parser.add_argument('--plugin', type=Path, default=Path.home() / '.hermes/plugins/conduit_push')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[2] / 'bridge/src/routines/delivery.py'
    print(json.dumps(install(args.plugin, source, apply=args.apply)))
