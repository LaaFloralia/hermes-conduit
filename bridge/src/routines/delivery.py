"""One durable hosted room for scheduled reports, independent of their runner.

The existing Hermes hosted-room transaction owns identity, replay and deduplication.
No user turn or room driver is started by report delivery.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
import time

ROOM_ID = 'laa-routines'
ROOM_NAME = '定期実行'
STAFF = {'laa-monet': 'Monet', 'laa-cos': 'Merlin', 'laa-cto': 'Ada',
         'laa-cio': 'Sherlock', 'laa-cso': 'Talos'}
PREFIX = 'laa-routine:'


def handles(profile):
    return profile in STAFF


def scheduled(job):
    values = job.get('deliver', '')
    values = values if isinstance(values, list) else str(values).split(',')
    return any(str(v).strip() == 'bot-chat' or str(v).strip().startswith('bot-chat:') for v in values)


def quiets(job_id):
    """Only the accepted group delivery notifies; the execution's scratch chat is silent."""
    try:
        from hermes_constants import get_hermes_home
        home = Path(get_hermes_home())
        if not handles(home.name):
            return False
        jobs = json.loads((home / 'cron/jobs.json').read_text())
        jobs = jobs.get('jobs', []) if isinstance(jobs, dict) else jobs
        return any(j.get('id') == job_id and scheduled(j) for j in jobs)
    except (OSError, ValueError, TypeError):
        return False


def route_label(route):
    if not isinstance(route, dict):
        return None
    provider, model, effort, reason = (route.get(k) for k in ('provider', 'model', 'effort', 'reason'))
    if (not all(isinstance(v, str) for v in (provider, model, effort, reason))
            or (provider, model) not in {('laa-dsh', 'deepseek-v4.1-flash'),
                ('dsh', '["opencode-go","deepseek-v4.1-flash"]'),
                ('laa-agy', 'gemini-4-hydrogen'), ('antigravity', 'gemini-4-hydrogen')}
            or effort not in ('low', 'high', 'max', 'xhigh')):
        return None
    reasons = {'usage_available': '残量あり', 'usage_unavailable': '残量不明',
               'quota_before_tools': '初回要求が枠切れ'}
    label = reasons.get(reason)
    if label is None and reason.startswith('quota_'):
        windows = reason[6:].split('_')
        names = {'5h': '5時間', 'weekly': '週間', 'monthly': '月間'}
        if windows and len(set(windows)) == len(windows) and all(w in names for w in windows):
            label = '枠切れ: ' + '・'.join(names[w] for w in windows)
    return f'{provider} / {model} / {effort}（{label}）' if label else None


def model_label(job, home):
    actual = route_label(job.get('_laa_routine_route'))
    if actual:
        return actual
    model = job.get('model') or job.get('model_name')
    if isinstance(model, dict):
        model = model.get('default') or model.get('name')
    if not model:
        try:
            import yaml
            config = yaml.safe_load((Path(home) / 'config.yaml').read_text()) or {}
            model = config.get('model')
            if isinstance(model, dict):
                model = model.get('default') or model.get('name')
        except (OSError, ValueError, ImportError):
            pass
    return ' '.join(str(model or 'モデル未記録').split())[:160]


def ensure_room(rooms, db_path, authority):
    members = [{'member_id': p, 'profile': p, 'handle': name, 'display_name': name,
                'target': {'kind': 'local', 'profile': p}} for p, name in STAFF.items()]
    return rooms.create_room(db_path, room_id=ROOM_ID, name=ROOM_NAME,
                             members=members, authority_gateway_id=authority)


def store_report(job, content, profile, *, rooms, db_path, authority, model,
                 redact, receipt_path, send, muted=False):
    if not handles(profile):
        raise ValueError('unsupported routine owner')
    execution = job.get('execution_id')
    if not execution:
        raise ValueError('a stable scheduled execution id is required')
    identity = f"{profile}:{job['id']}:{execution}"
    event_id = 'routine:' + hashlib.sha256(identity.encode()).hexdigest()
    # The same redactor as Hermes delivery runs before durable storage and push.
    name = ' '.join(redact(str(job.get('name') or job['id']), 'job name').split())
    body = redact(str(content), 'routine report')
    model = redact(model, 'routine model')
    text = f"## {name}\n担当: {STAFF[profile]} · {model}\n\n{body}"
    room = ensure_room(rooms, db_path, authority)
    event = rooms.append_event(db_path, room_id=ROOM_ID, event_id=event_id,
        kind='message.member', actor={'kind': 'member', 'id': profile, 'profile': profile,
        'display_name': STAFF[profile]}, payload={'text': text, 'routine': {
            'job_id': str(job['id']), 'execution_id': str(execution), 'profile': profile,
            'model': model, 'runner': str(job.get('routine_runner') or 'hermes')}},
        authority_gateway_id=authority, authority_epoch=room['authority_epoch'])
    # Crash after append/before push retries this event, never a second message.
    receipt_path = Path(receipt_path)
    receipt_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with sqlite3.connect(receipt_path, timeout=20) as db:
        db.execute('CREATE TABLE IF NOT EXISTS notifications (event_id TEXT PRIMARY KEY, sent_at REAL)')
        db.execute('BEGIN IMMEDIATE')
        previous = db.execute('SELECT sent_at FROM notifications WHERE event_id=?', (event_id,)).fetchone()
        if previous is None:
            if not muted:
                send({'type': 'response.ready', 'event_id': event_id, 'profile': profile,
                      'session_id': PREFIX + ROOM_ID + ':' + str(event['seq']) + ':' + event_id,
                      'room': {'id': ROOM_ID}, 'title': f'{ROOM_NAME} · {name}', 'body': text[:500]})
            sent_at = None if muted else time.time()
            db.execute('INSERT INTO notifications VALUES (?,?)', (event_id, sent_at))
        else:
            sent_at = previous[0]
    receipt = {'status': 'shown', 'destination': 'group:' + ROOM_ID,
               'room_id': ROOM_ID, 'event_id': event_id, 'seq': event['seq'], 'delivery_id': identity,
               'notification_status': 'muted' if sent_at is None else 'accepted'}
    job.setdefault('_bot_chat_delivery_receipts', {})['group:' + ROOM_ID] = receipt
    return receipt


def show(job, content, profile, *, for_failure=False):
    """Plugin entry: fail visibly rather than fall back into a personal chat."""
    try:
        from gateway import hosted_rooms as rooms
        # Directory plugins live under hermes_plugins.<slug> in the gateway.
        # Only standalone Work/Dots/Muse processes use the bare package path.
        if __package__:
            from . import client, cron_runs, cron_bot_chat
            from .cron_store import CronStore
        else:
            from conduit_push import client, cron_runs, cron_bot_chat
            from conduit_push.cron_store import CronStore
        home = cron_bot_chat._target_home(profile)
        if cron_runs.is_silent(content) or str(content).strip() == "NO_REPORT":
            job['_notification_all_targets_suppressed'] = True
            return None
        redactor = getattr(cron_bot_chat._delivery_module(), '_redact_cron_payload', None)
        if not callable(redactor):
            raise RuntimeError('Hermes redaction is unavailable')
        # Convert media using the same vocabulary as existing report cards.
        content = cron_bot_chat.reference_tags(content)
        root = home.parent.parent if home.parent.name == 'profiles' else home
        store_report(job, content, profile, rooms=rooms, db_path=root / 'shared-state.db',
                     authority=rooms.local_authority_gateway_id(), model=model_label(job, home),
                     redact=redactor, receipt_path=root / 'conduit-routine-notifications.db',
                     send=client.send_now, muted=CronStore(home).is_muted(job['id']))
        return None
    except Exception as error:
        return f'routine room delivery failed: {type(error).__name__}'


def bootstrap():
    """CLI uses the installed dependency environment and pairing, never copies secrets."""
    src = Path.home() / '.local/share/hermes-agent'
    sys.path.insert(0, str(src))
    sys._hermes_pin_default_home = True
    os.environ['HERMES_HOME'] = str(Path.home() / '.hermes/profiles/laa-monet')
    from pm.environments import activate_dependencies
    activate_dependencies(src)
    sys.path.insert(1, str(Path.home() / '.hermes/plugins'))


def scan_work(jobs_path, state_path):
    """Read Work's durable completed runs, including runs auto-archived before polling."""
    state_path = Path(state_path)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    if not state_path.exists():
        state_path.write_text(json.dumps({'since': time.time()}))
    state = json.loads(state_path.read_text())
    since = state['since']
    document = json.loads(Path(jobs_path).read_text())
    jobs = document.values() if isinstance(document, dict) else document
    from datetime import datetime
    failures = []
    for job in jobs:
        for run in job.get('runs', []):
            if run.get('status') not in ('succeeded', 'failed') or not run.get('endedAt'):
                continue
            if datetime.fromisoformat(run['endedAt'].replace('Z', '+00:00')).timestamp() < since:
                continue
            # Freeze the actual run's model before delivery. Later job edits must
            # not change an immutable event when the watcher retries that run.
            records = state.setdefault('runs', {})
            if records.get(run['id'], {}).get('delivered'):
                continue
            if run['id'] not in records:
                import subprocess
                model = None
                if run.get('agentId'):
                    try:
                        done = subprocess.run([str(Path.home() / '.local/bin/laa-work'), 'inspect',
                            run['agentId'], '--json'], capture_output=True, text=True, timeout=20)
                        if done.returncode == 0:
                            agent = json.loads(done.stdout)
                            model = agent.get('RuntimeModel') or agent.get('Model') or agent.get('Provider')
                    except (OSError, ValueError, subprocess.TimeoutExpired):
                        pass
                config = job.get('target', {}).get('config', {})
                records[run['id']] = {'model': route_label(run.get('modelRoute')) or model or config.get('model') or config.get('provider') or 'モデル未記録',
                                      'name': job['name']}
                temporary = state_path.with_suffix('.tmp')
                temporary.write_text(json.dumps(state))
                temporary.replace(state_path)
            request = {'id': 'work-' + job['id'], 'name': records[run['id']]['name'], 'execution_id': run['id'],
                       'model': records[run['id']]['model'], 'routine_runner': 'work'}
            error = show(request, run.get('output') or run.get('error') or '報告本文がありません。', 'laa-monet')
            if error:
                failures.append({'run': run['id'], 'error': error})
            else:
                records[run['id']]['delivered'] = True
                temporary = state_path.with_suffix('.tmp')
                temporary.write_text(json.dumps(state))
                temporary.replace(state_path)
    return {'errors': failures}


if __name__ == '__main__':
    bootstrap()
    if len(sys.argv) > 1 and sys.argv[1] == 'scan-work':
        result = scan_work(sys.argv[2], sys.argv[3])
    else:
        request = json.load(sys.stdin)
        error = show(request['job'], request['content'], request['profile'])
        result = {'error': error, 'receipt': request['job'].get('_bot_chat_delivery_receipts')}
    print(json.dumps(result, ensure_ascii=False))
