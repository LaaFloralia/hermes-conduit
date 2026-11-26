"""Scheduled reports go to the responsible staff member's own Chat, whoever ran them.

The job's `deliver: bot-chat:<profile>` names the staff member who reports; the run itself may
be code or any model. The report is written into that profile's Bot Chat as a note (no AI turn,
the Conduit "just show it" form the app renders as a report card) and one push opens that chat.

Repeated failures (hq/tools/RUNTIME.md "定期処理"): the first failure is shown; the second
identical one opens a fix (Linear, through laa-agent) and says so once; later identical failures
are silent until a run succeeds, which says it recovered. Every outcome is recorded for Monet's
daily digest, so Monet's own chat never receives other staff's routine cards.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time

STAFF = {'laa-monet': 'Monet', 'laa-cos': 'Merlin', 'laa-cto': 'Ada', 'laa-cfo': 'Morgan',
         'laa-cio': 'Sherlock', 'laa-cso': 'Talos', 'laa-argus': 'Argus'}
# laa-agent files Linear issues for these roles only.
FIX_ROLE = {'laa-monet': 'COS', 'laa-cos': 'COS', 'laa-cto': 'CTO', 'laa-cfo': 'CFO',
            'laa-cio': 'CIO', 'laa-cso': 'CTO', 'laa-argus': 'CIO'}
FAILURE_MARKS = ('[CRON_FAILURE]', '障害:', '障害：')
CODE = re.compile(r'\b([a-z][a-z0-9]*(?:_[a-z0-9]+)+)\b')
LAA_AGENT = Path.home() / '.local/bin/laa-agent'


def handles(profile):
    return profile in STAFF


def scheduled(job):
    values = job.get('deliver', '')
    values = values if isinstance(values, list) else str(values).split(',')
    return any(str(v).strip() == 'bot-chat' or str(v).strip().startswith('bot-chat:') for v in values)


def quiets(job_id):
    """Only the staff chat's own push notifies; the execution's scratch chat is silent."""
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


def failure_signature(content, for_failure=False):
    """None for a normal report, else a stable key for "the same failure again"."""
    lines = [line.strip() for line in str(content or '').strip().splitlines() if line.strip()]
    first = lines[0] if lines else ''
    if not for_failure and not first.startswith(FAILURE_MARKS):
        return None
    if first == '[CRON_FAILURE]':
        first = lines[1] if len(lines) > 1 else first
    code = CODE.search(first) or CODE.search(' '.join(lines[:3]))
    if code:
        return code.group(1)
    return re.sub(r'[\d:./-]+', '#', first)[:160]


def _db(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    db = sqlite3.connect(path, timeout=20)
    db.execute('CREATE TABLE IF NOT EXISTS notifications (event_id TEXT PRIMARY KEY, sent_at REAL)')
    db.execute('CREATE TABLE IF NOT EXISTS routine_failures (job_key TEXT PRIMARY KEY, signature TEXT, '
               'count INTEGER, fix_ref TEXT, first_at REAL, last_at REAL)')
    db.execute('CREATE TABLE IF NOT EXISTS routine_reports (event_id TEXT PRIMARY KEY, profile TEXT, job_id TEXT, '
               'job_name TEXT, execution_id TEXT, outcome TEXT, signature TEXT, fix_ref TEXT, at REAL)')
    return db


def open_fix(profile, job, signature, content):
    """A Linear Todo for the responsible staff; the report says where the fix lives."""
    title = f"定期実行の修理: {job.get('name') or job['id']}（{signature}）"[:120]
    summary = (f"目的: 定期実行「{job.get('name') or job['id']}」（{profile} / {job['id']}）が同じ障害で2回続けて止まった。\n"
               f"次の一手: 原因を直し、次の回が通ることを実行記録で確かめる。\n完了条件: 同じjobの回が成功する。\n\n"
               f"直近の報告（先頭）:\n{str(content)[:600]}")
    try:
        done = subprocess.run([str(LAA_AGENT), 'request', '--title', title, '--summary', summary,
                               '--role', FIX_ROLE.get(profile, 'COS'), '--from', f"routine:{job['id']}"],
                              capture_output=True, text=True, timeout=60)
        found = re.search(r'\b[A-Z]{2,6}-\d+\b', done.stdout + done.stderr)
        return found.group(0) if done.returncode == 0 and found else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def compose(job, content, profile, db, *, for_failure, now, fix):
    """(text to show or None for silence, outcome, signature, fix_ref) under the repeat rule."""
    key = f"{profile}:{job['id']}"
    signature = failure_signature(content, for_failure)
    row = db.execute('SELECT signature, count, fix_ref FROM routine_failures WHERE job_key=?', (key,)).fetchone()
    if signature is None:
        db.execute('DELETE FROM routine_failures WHERE job_key=?', (key,))
        if row and row[1] >= 2:
            return f"直りました{('（' + row[2] + '）') if row[2] else ''}。\n\n{content}", 'recovered', None, row[2]
        return content, 'shown', None, None
    count = row[1] + 1 if row and row[0] == signature else 1
    fix_ref = row[2] if row and row[0] == signature else None
    if count == 2:
        fix_ref = fix(profile, job, signature, content)
    db.execute('INSERT OR REPLACE INTO routine_failures VALUES (?,?,?,?,COALESCE((SELECT first_at FROM routine_failures '
               'WHERE job_key=? AND signature=?),?),?)', (key, signature, count, fix_ref, key, signature, now, now))
    if count == 1:
        return content, 'failure', signature, None
    if count == 2:
        where = f"Linear {fix_ref}" if fix_ref else 'Linearへの登録に失敗、実行記録に残しています'
        first = next((line for line in str(content).splitlines() if line.strip() and line.strip() != '[CRON_FAILURE]'), '')
        return (f"同じ障害が2回続いたため、修理に回しました（{where}）。直るまでこの件は報告せず、直ったらお知らせします。\n\n{first}",
                'fix_opened', signature, fix_ref)
    return None, 'suppressed', signature, fix_ref


NOTE_WAIT_S, NOTE_RETRY_S = 60.0, 5.0


def write_bot_chat_note(home, text, key, for_failure=False, *, sleep=time.sleep, clock=time.monotonic):
    """The report as a note row in the profile's Bot Chat (no turn). A turn holding the chat refuses
    the write, so it waits for that turn; `key` keeps a retried run to one row."""
    from hermes_state import SessionDB
    metadata = {'completion_note': [key], 'conduit_cron_report': True}
    if for_failure:
        metadata['notification_category'] = 'diagnostic'
    deadline = clock() + NOTE_WAIT_S
    while True:
        db = SessionDB(db_path=Path(home) / 'state.db')
        try:
            row = db.get_session_by_title('Bot Chat')
            chat = db.get_compression_tip(row['id']) if row else None
            if not chat:
                raise LookupError('no Bot Chat yet')
            if not db.has_platform_message_id(chat, key):
                db.append_message(chat, 'user', content=text, platform_message_id=key,
                                  display_kind='internal_notification', display_metadata=metadata)
            return chat
        except LookupError:
            raise
        except Exception:  # noqa: BLE001 - a running turn or a busy database; retried until the wait is up
            if clock() + NOTE_RETRY_S > deadline:
                raise
        finally:
            db.close()
        sleep(NOTE_RETRY_S)


def store_report(job, content, profile, *, write_note, send, receipt_path, muted=False,
                 for_failure=False, fix=open_fix, now=time.time):
    """Show one run's report in the staff member's chat once; retries never duplicate it."""
    if not handles(profile):
        raise ValueError('unsupported routine owner')
    execution = job.get('execution_id')
    if not execution:
        raise ValueError('a stable scheduled execution id is required')
    identity = f"{profile}:{job['id']}:{execution}"
    event_id = 'routine:' + hashlib.sha256(identity.encode()).hexdigest()
    with _db(receipt_path) as db:
        db.execute('BEGIN IMMEDIATE')
        done = db.execute('SELECT outcome, fix_ref FROM routine_reports WHERE event_id=?', (event_id,)).fetchone()
        if done is None:
            text, outcome, signature, fix_ref = compose(job, content, profile, db, for_failure=for_failure,
                                                        now=now(), fix=fix)
            db.execute('INSERT INTO routine_reports VALUES (?,?,?,?,?,?,?,?,?)',
                       (event_id, profile, str(job['id']), str(job.get('name') or job['id']), str(execution),
                        outcome, signature, fix_ref, now()))
        else:
            # A retried run re-shows the decided text, never re-decides the repeat rule.
            outcome, fix_ref = done
            text = None if outcome == 'suppressed' else content
        receipt = {'status': 'suppressed' if text is None else 'shown', 'destination': 'bot-chat:' + profile,
                   'event_id': event_id, 'delivery_id': identity, 'outcome': outcome, 'fix_ref': fix_ref}
        if text is None:
            job['_notification_all_targets_suppressed'] = True
            job.setdefault('_bot_chat_delivery_receipts', {})['bot-chat:' + profile] = receipt
            return receipt
        chat = write_note(text, f"conduit-cron:{job['id']}:{execution}")
        previous = db.execute('SELECT sent_at FROM notifications WHERE event_id=?', (event_id,)).fetchone()
        if previous is None:
            if not muted:
                send({'event_id': event_id, 'profile': profile, 'session_id': chat,
                      'title': f"{STAFF[profile]} · {' '.join(str(job.get('name') or job['id']).split())}",
                      'body': text[:500]})
            db.execute('INSERT INTO notifications VALUES (?,?)', (event_id, None if muted else now()))
            sent_at = None if muted else now()
        else:
            sent_at = previous[0]
    receipt['notification_status'] = 'muted' if sent_at is None else 'accepted'
    receipt['session_id'] = chat
    job.setdefault('_bot_chat_delivery_receipts', {})['bot-chat:' + profile] = receipt
    return receipt


def digest(receipt_path, since):
    """Per staff: runs, open failures and fixes since `since` (Monet's one line per staff)."""
    try:
        db = sqlite3.connect(f'file:{receipt_path}?mode=ro', uri=True, timeout=5)
    except sqlite3.Error:
        return None
    try:
        rows = db.execute('SELECT profile, outcome, job_name, fix_ref FROM routine_reports WHERE at>=? ORDER BY at',
                          (since,)).fetchall()
        open_rows = db.execute('SELECT job_key, signature, count, fix_ref FROM routine_failures').fetchall()
    except sqlite3.Error:
        return None
    finally:
        db.close()
    staff = {}
    for profile, outcome, name, fix_ref in rows:
        entry = staff.setdefault(profile, {'name': STAFF.get(profile, profile), 'runs': 0, 'failures': [], 'fixes': []})
        entry['runs'] += 1
    for job_key, signature, count, fix_ref in open_rows:
        profile = job_key.split(':', 1)[0]
        entry = staff.setdefault(profile, {'name': STAFF.get(profile, profile), 'runs': 0, 'failures': [], 'fixes': []})
        (entry['fixes'] if count >= 2 else entry['failures']).append({'job': job_key.split(':', 1)[1],
                                                                        'signature': signature, 'fix': fix_ref})
    return staff


def show(job, content, profile, *, for_failure=False):
    """Plugin entry: fail visibly rather than fall back into another chat."""
    try:
        from hermes_constants import get_hermes_home, set_hermes_home_override, reset_hermes_home_override
        # Directory plugins live under hermes_plugins.<slug> in the gateway.
        # Only standalone Work processes use the bare package path.
        if __package__:
            from . import client, cron_runs, cron_bot_chat
            from .cron_store import CronStore
            from .events import push_event, plain_text
        else:
            from conduit_push import client, cron_runs, cron_bot_chat
            from conduit_push.cron_store import CronStore
            from conduit_push.events import push_event, plain_text
        if cron_runs.is_silent(content) or str(content).strip() == 'NO_REPORT':
            job['_notification_all_targets_suppressed'] = True
            return None
        if not callable(getattr(cron_bot_chat._delivery_module(), '_redact_cron_payload', None)):
            raise RuntimeError('Hermes redaction is unavailable')
        running = Path(get_hermes_home())
        home = cron_bot_chat._target_home(profile)
        root = home.parent.parent if home.parent.name == 'profiles' else home

        def write_note(text, key):
            return write_bot_chat_note(home, cron_bot_chat.note_text(job, text), key, for_failure)

        def send(event):
            # The staff member's own pairing, so the tap opens that member's chat.
            token = set_hermes_home_override(str(home))
            try:
                client.send_now(push_event('response.ready', identifier=event['event_id'],
                    session_id=event['session_id'], profile=profile, profile_name=STAFF[profile],
                    title=event['title'], title_label='response.ready', session_title=STAFF[profile],
                    body=plain_text(event['body'])))
            finally:
                reset_hermes_home_override(token)

        store_report(job, content, profile, write_note=write_note, send=send,
                     receipt_path=root / 'conduit-routine-notifications.db',
                     muted=CronStore(running).is_muted(job['id']), for_failure=for_failure)
        return None
    except Exception as error:
        return f'routine delivery to bot-chat:{profile} failed: {type(error).__name__}: {str(error)[:200]}'


def bootstrap():
    """CLI uses the installed dependency environment and pairing, never copies secrets."""
    src = Path.home() / '.local/share/hermes-agent'
    sys.path.insert(0, str(src))
    sys._hermes_pin_default_home = True
    os.environ['HERMES_HOME'] = str(Path.home() / '.hermes/profiles/laa-monet')
    from pm.environments import activate_dependencies
    activate_dependencies(src)
    sys.path.insert(1, str(Path.home() / '.hermes/plugins'))


def scan_work(jobs_path, state_path, profile='laa-cto'):
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
            records = state.setdefault('runs', {})
            if records.get(run['id'], {}).get('delivered'):
                continue
            records.setdefault(run['id'], {'name': job['name']})
            request = {'id': 'work-' + job['id'], 'name': records[run['id']]['name'], 'execution_id': run['id'],
                       'routine_runner': 'work'}
            error = show(request, run.get('output') or run.get('error') or '報告本文がありません。', profile,
                         for_failure=run.get('status') == 'failed')
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
        result = scan_work(sys.argv[2], sys.argv[3], *(sys.argv[4:5]))
    elif len(sys.argv) > 1 and sys.argv[1] == 'digest':
        result = digest(Path.home() / '.hermes/conduit-routine-notifications.db', float(sys.argv[2]))
    else:
        request = json.load(sys.stdin)
        error = show(request['job'], request['content'], request['profile'])
        result = {'error': error, 'receipt': request['job'].get('_bot_chat_delivery_receipts')}
    print(json.dumps(result, ensure_ascii=False))
