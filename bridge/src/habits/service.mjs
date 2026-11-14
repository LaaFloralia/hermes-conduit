import { createHash, randomUUID } from 'node:crypto';
import { BridgeError } from '../errors.mjs';
import { IDEMPOTENCY_KEY_PATTERN } from '../idempotency.mjs';
import { MAX_EVENTS, OP_RETENTION_MS } from './store.mjs';
import { addDays, isDate, TIME_ZONE, tokyoDate, weekFor } from './dates.mjs';

const FIELDS = ['title', 'note', 'weeklyTarget', 'minutes', 'minimum', 'support'];
const length = (value) => [...value].length;
const own = (value, key) => Object.hasOwn(value, key);
const publicHabit = ({ targets, ...habit }) => structuredClone(habit);
const fail = (status, code, message, details) => { throw new BridgeError(status, code, message, { details }); };
const invalid = (field, message = `invalid ${field}`) => fail(400, 'habit_invalid', message, { field });

function object(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) invalid('body');
  return body;
}

function actorContext({ actor = 'owner', agent = null, reason = null } = {}, write = false) {
  if (!['owner', 'agent'].includes(actor)) invalid('actor');
  if (actor === 'agent' && write) {
    if (typeof agent !== 'string' || !agent.trim()) invalid('agent');
    if (typeof reason !== 'string' || !reason.trim() || length(reason.trim()) > 200) invalid('reason');
  }
  return { actor, agent: actor === 'agent' ? agent?.trim() ?? null : null, reason: actor === 'agent' ? reason?.trim() ?? null : null };
}

function validateFields(body, { create = false, kind, actor }) {
  object(body);
  if (actor === 'agent' && own(body, 'support')) fail(403, 'habit_support_owner_only', 'only the owner can set support');
  const allowed = create ? ['kind', ...FIELDS] : [...FIELDS, 'archived'];
  for (const field of Object.keys(body)) if (!allowed.includes(field)) invalid(field);
  if (create && !['do', 'avoid'].includes(body.kind)) invalid('kind');
  const result = {};
  if (create || own(body, 'title')) {
    if (typeof body.title !== 'string' || /[\x00-\x1f\x7f-\x9f]/u.test(body.title)) invalid('title');
    result.title = body.title.trim();
    if (length(result.title) < 1 || length(result.title) > 80) invalid('title');
  }
  if (create || own(body, 'weeklyTarget')) {
    const value = body.weeklyTarget;
    if (!Number.isInteger(value) || value < (kind === 'do' ? 1 : 0) || value > 7) invalid('weeklyTarget');
    result.weeklyTarget = value;
  }
  if (create || own(body, 'note')) {
    const value = own(body, 'note') ? body.note : '';
    if (typeof value !== 'string' || length(value) > 500) invalid('note');
    result.note = value;
  }
  if (create || own(body, 'minutes')) {
    const value = own(body, 'minutes') ? body.minutes : null;
    if (value !== null && (!Number.isInteger(value) || value < 1 || value > 600)) invalid('minutes');
    result.minutes = value;
  }
  if (create || own(body, 'minimum')) {
    const value = own(body, 'minimum') ? body.minimum : null;
    if (value !== null && (typeof value !== 'string' || length(value) < 1 || length(value) > 80)) invalid('minimum');
    result.minimum = value;
  }
  if (create || own(body, 'support')) {
    const value = own(body, 'support') ? body.support : 'ask';
    if (!['off', 'ask', 'plan'].includes(value)) invalid('support');
    result.support = value;
  }
  if (own(body, 'archived')) {
    if (typeof body.archived !== 'boolean') invalid('archived');
    result.archived = body.archived;
  }
  return result;
}

function integer(value, fallback, max, field) {
  if (value === undefined || value === null) return fallback;
  if ((typeof value !== 'number' && (typeof value !== 'string' || !/^\d+$/.test(value)))
      || !Number.isInteger(Number(value)) || Number(value) < 1 || Number(value) > max) invalid(field);
  return Number(value);
}

export const habitETag = (revision) => `"${revision}"`;

export function createHabitService({ store, now = () => Date.now() } = {}) {
  function today() { return tokyoDate(now()); }
  function find(state, id, ctx) {
    const habit = state.habits.find((item) => item.id === id);
    if (!habit) fail(404, 'habit_not_found', 'no such habit');
    if (ctx.actor === 'agent' && habit.support === 'off') fail(403, 'habit_support_off', 'habit is outside the permitted support');
    return habit;
  }
  function visible(habit, ctx) { return ctx.actor !== 'agent' || habit.support !== 'off'; }
  function weekItem(state, habit, week) {
    const target = [...habit.targets].reverse().find((entry) => entry.from <= week.start)?.weeklyTarget ?? habit.weeklyTarget;
    const dates = state.checkins[habit.id] ?? [];
    const days = week.days.map((date) => dates.includes(date));
    const count = days.filter(Boolean).length;
    return { ...publicHabit(habit), target, days, count, met: habit.kind === 'do' ? count >= target : count <= target };
  }
  function itemsFor(state, habits, week) {
    return habits.filter((h) => h.createdOn <= week.end && (!h.archivedOn || h.archivedOn > week.end))
      .sort((a, b) => (a.kind === b.kind ? a.createdAt.localeCompare(b.createdAt) : a.kind === 'do' ? -1 : 1))
      .map((habit) => weekItem(state, habit, week));
  }
  function event(state, habit, type, ctx, changes = {}, date = null) {
    state.events.unshift({ id: randomUUID(), at: new Date(now()).toISOString(), ...ctx,
      type, habitId: habit.id, title: habit.title, changes, date });
    state.events.length = Math.min(state.events.length, MAX_EVENTS);
  }
  function changesFor(before, patch) {
    return Object.fromEntries(Object.entries(patch).filter(([key, value]) => value !== before[key])
      .map(([key, value]) => [key, key === 'note'
        ? { fromLength: length(before[key] ?? ''), toLength: length(value) }
        : { from: before[key] ?? null, to: value }]));
  }

  return {
    today,
    week({ week: date, ...context } = {}) {
      const ctx = actorContext(context);
      date ??= today();
      if (!isDate(date) || date < '2020-01-01' || date > addDays(today(), 366)) fail(400, 'habit_week_invalid', 'week must be a valid date from 2020 through today + 366 days');
      const state = store.read();
      const habits = state.habits.filter((h) => visible(h, ctx));
      const week = weekFor(date);
      return { week: { ...week, current: week.start === weekFor(today()).start }, today: today(), timeZone: TIME_ZONE,
        items: itemsFor(state, habits, week), archivedCount: habits.filter((h) => h.archivedOn).length,
        ...(ctx.actor === 'agent' ? { withheld: state.habits.length - habits.length } : {}) };
    },
    history({ weeks, ...context } = {}) {
      const ctx = actorContext(context);
      const count = integer(weeks, 8, 26, 'weeks');
      const state = store.read();
      const habits = state.habits.filter((h) => visible(h, ctx));
      const oldest = habits.map((h) => weekFor(h.createdOn).start).sort()[0];
      const result = [];
      for (let i = 1; i <= count; i++) {
        const week = weekFor(addDays(weekFor(today()).start, -7 * i));
        if (!oldest || week.start < oldest) break;
        result.push({ start: week.start, end: week.end,
          items: itemsFor(state, habits, week).map(({ id, kind, title, target, count, met }) => ({ id, kind, title, target, count, met })) });
      }
      return { weeks: result, ...(ctx.actor === 'agent' ? { withheld: state.habits.length - habits.length } : {}) };
    },
    archived(context = {}) {
      const ctx = actorContext(context);
      const archived = store.read().habits.filter((h) => h.archivedOn);
      const habits = archived.filter((h) => visible(h, ctx));
      return { items: habits.sort((a, b) => b.archivedAt.localeCompare(a.archivedAt)).map(publicHabit),
        ...(ctx.actor === 'agent' ? { withheld: archived.length - habits.length } : {}) };
    },
    events({ limit, cursor, ...context } = {}) {
      const ctx = actorContext(context);
      const count = integer(limit, 50, 100, 'limit');
      const state = store.read();
      const allowed = new Set(state.habits.filter((h) => visible(h, ctx)).map((h) => h.id));
      const events = state.events.filter((e) => allowed.has(e.habitId));
      let start = 0;
      if (cursor !== undefined && cursor !== null && cursor !== '') {
        const index = events.findIndex((e) => e.id === cursor);
        if (index < 0) invalid('cursor');
        start = index + 1;
      }
      const items = events.slice(start, start + count);
      return { items: structuredClone(items), nextCursor: start + count < events.length ? items.at(-1).id : null,
        ...(ctx.actor === 'agent' ? { withheld: state.events.length - events.length } : {}) };
    },
    create({ body, key, principal = 'owner', ...context }) {
      const ctx = actorContext(context, true);
      if (key === undefined || key === '') fail(400, 'idempotency_key_required', 'a creation key is required');
      if (typeof key !== 'string' || !IDEMPOTENCY_KEY_PATTERN.test(key)) fail(400, 'idempotency_key_invalid', 'invalid creation key');
      if (ctx.actor === 'agent' && body && own(body, 'support')) fail(403, 'habit_support_owner_only', 'only the owner can set support');
      const opKey = createHash('sha256').update(JSON.stringify([ctx.actor, principal, key])).digest('hex');
      return store.mutate((state) => {
        const prior = state.ops[opKey];
        if (prior && now() - Date.parse(prior.at) < OP_RETENTION_MS) {
          return { habit: publicHabit(find(state, prior.habitId, ctx)), replayed: true, status: 200 };
        }
        const fields = validateFields(body, { create: true, kind: body?.kind, actor: ctx.actor });
        const at = new Date(now()).toISOString();
        const habit = { id: randomUUID(), kind: body.kind, ...fields, createdAt: at, createdOn: today(),
          updatedAt: at, archivedAt: null, archivedOn: null, revision: 1,
          targets: [{ from: weekFor(today()).start, weeklyTarget: fields.weeklyTarget }] };
        state.habits.push(habit);
        state.checkins[habit.id] = [];
        for (const [key, op] of Object.entries(state.ops)) if (now() - Date.parse(op.at) >= OP_RETENTION_MS) delete state.ops[key];
        state.ops[opKey] = { habitId: habit.id, at };
        event(state, habit, 'habit.created', ctx, changesFor({}, { kind: habit.kind, ...fields }));
        return { habit: publicHabit(habit), replayed: false, status: 201 };
      });
    },
    update({ id, body, ifMatch, ...context }) {
      const ctx = actorContext(context, true);
      return store.mutate((state) => {
        const habit = find(state, id, ctx);
        if (ifMatch === undefined || ifMatch === null || ifMatch === '') fail(428, 'habit_if_match_required', 'If-Match is required');
        const match = /^(?:"([1-9]\d*)"|([1-9]\d*))$/.exec(String(ifMatch));
        if (!match) invalid('ifMatch');
        if (Number(match[1] ?? match[2]) !== habit.revision) fail(412, 'habit_revision_mismatch', 'habit has changed', { revision: habit.revision });
        const patch = validateFields(body, { kind: habit.kind, actor: ctx.actor });
        if (habit.archivedOn && (patch.archived === undefined || Object.keys(patch).length !== 1)) fail(409, 'habit_archived', 'restore the habit before editing');
        const { archived, ...fields } = patch;
        const changes = changesFor(habit, fields);
        const archiveChanged = archived !== undefined && archived !== Boolean(habit.archivedOn);
        if (!Object.keys(changes).length && !archiveChanged) return publicHabit(habit);
        if (changes.weeklyTarget) {
          const from = weekFor(today()).start;
          habit.targets = habit.targets.filter((entry) => entry.from !== from);
          habit.targets.push({ from, weeklyTarget: fields.weeklyTarget });
          habit.targets.sort((a, b) => a.from.localeCompare(b.from));
        }
        Object.assign(habit, fields);
        if (archiveChanged) {
          changes.archived = { from: !archived, to: archived };
          habit.archivedAt = archived ? new Date(now()).toISOString() : null;
          habit.archivedOn = archived ? today() : null;
        }
        habit.revision++;
        habit.updatedAt = new Date(now()).toISOString();
        event(state, habit, archiveChanged ? archived ? 'habit.archived' : 'habit.restored' : 'habit.updated', ctx, changes);
        return publicHabit(habit);
      });
    },
    check({ id, date, body, ...context }) {
      const ctx = actorContext(context, true);
      object(body);
      for (const key of Object.keys(body)) if (key !== 'done') invalid(key);
      if (typeof body.done !== 'boolean') invalid('done');
      if (!isDate(date)) fail(400, 'habit_date_invalid', 'date must be YYYY-MM-DD');
      if (date > today()) fail(400, 'habit_date_future', 'cannot record a future date');
      return store.mutate((state) => {
        const habit = find(state, id, ctx);
        if (habit.archivedOn) fail(409, 'habit_archived', 'restore the habit before recording');
        if (date < weekFor(habit.createdOn).start) fail(400, 'habit_date_before_start', 'date is before the creation week');
        const dates = state.checkins[habit.id] ?? [];
        if (dates.includes(date) !== body.done) {
          state.checkins[habit.id] = body.done ? [...dates, date].sort() : dates.filter((d) => d !== date);
          event(state, habit, body.done ? 'checkin.set' : 'checkin.cleared', ctx, { done: { from: !body.done, to: body.done } }, date);
        }
        const week = weekFor(date);
        const item = weekItem(state, habit, week);
        return { habitId: id, date, done: body.done, week: { start: week.start, count: item.count, target: item.target, met: item.met } };
      });
    },
  };
}
