import { readFileSync, writeFileSync, renameSync } from 'node:fs';
import { notifyOwner } from '../notify/index.mjs';

// Google email reminders remain Google's responsibility. Popup reminders are
// delivered through the app's single owner-notification entry point.
export function createCalendarReminders({ service, notify = notifyOwner, now = Date.now, file } = {}) {
  let running = false;
  let sent = {};
  try { sent = JSON.parse(readFileSync(file, 'utf8')); } catch { }
  function persist() {
    if (!file) return;
    const temporary = `${file}.tmp`;
    writeFileSync(temporary, JSON.stringify(sent), { mode: 0o600 }); renameSync(temporary, file);
  }
  return {
    async tick() {
      if (running) return;
      running = true;
      try {
        const time = now();
        const calendars = (await service.calendars()).items.filter(c => c.selected);
        for (const calendar of calendars) {
          const events = await service.list({ start: new Date(time - 2 * 86400_000).toISOString(),
            end: new Date(time + 29 * 86400_000).toISOString(), calendarIds: [calendar.id] });
          for (const event of events.items) {
            // Date-only starts belong to the calendar timezone, not UTC.
            let start = Date.parse(event.start);
            if (event.allDay) {
              const zone = calendar.timeZone ?? 'Asia/Tokyo';
              for (let i = 0; i < 2; i++) {
                const parts = Object.fromEntries(new Intl.DateTimeFormat('en-CA', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit',
                  hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' }).formatToParts(start).map(p => [p.type,p.value]));
                const local = Date.UTC(+parts.year,+parts.month-1,+parts.day,+parts.hour,+parts.minute,+parts.second);
                start -= local - Date.parse(`${event.start}T00:00:00Z`);
              }
            }
            const reminders = event.reminders?.useDefault ? calendar.defaultReminders : event.reminders?.overrides;
            for (const reminder of reminders ?? []) {
              if (reminder.method !== 'popup') continue;
              const due = start - reminder.minutes * 60_000;
              if (due > time || due < time - 24 * 3600_000) continue;
              const key = `calendar:${calendar.id}:${event.id}:${event.start}:${reminder.minutes}`;
              if (sent[key]) continue;
              const result = await notify({ kind: 'calendar', title: event.title, body: event.allDay ? '終日の予定' : event.start,
                deepLink: `laa://today/events/${encodeURIComponent(event.id)}?calendar=${encodeURIComponent(calendar.id)}`, dedupeKey: key });
              if (result.delivered) { sent[key] = time; persist(); }
            }
          }
        }
        sent = Object.fromEntries(Object.entries(sent).filter(([,time]) => time > now() - 8 * 86400_000));
      } finally { running = false; }
    },
  };
}
