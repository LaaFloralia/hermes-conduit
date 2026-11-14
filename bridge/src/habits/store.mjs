import { chmodSync, copyFileSync, constants, existsSync, mkdirSync, readdirSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { BridgeError } from '../errors.mjs';
import { createJsonFile, StateFileError } from '../routes/state-file.mjs';
import { isDate, tokyoDate, weekFor } from './dates.mjs';

export const OP_RETENTION_MS = 7 * 86_400_000;
export const MAX_EVENTS = 2000;
const BACKUP_NAME = /^habits-\d{4}-\d{2}-\d{2}\.json$/;
class Unchanged { constructor(result) { this.result = result; } }
const text = (value, min, max) => typeof value === 'string' && [...value].length >= min && [...value].length <= max;
const timestamp = (value) => typeof value === 'string' && Number.isFinite(Date.parse(value));
const target = (value, kind) => Number.isInteger(value) && value >= (kind === 'do' ? 1 : 0) && value <= 7;

function validHabit(habit) {
  return habit && typeof habit.id === 'string' && ['do', 'avoid'].includes(habit.kind)
    && text(habit.title, 1, 80) && !/[\x00-\x1f\x7f-\x9f]/u.test(habit.title)
    && text(habit.note, 0, 500) && target(habit.weeklyTarget, habit.kind)
    && (habit.minutes === null || (Number.isInteger(habit.minutes) && habit.minutes >= 1 && habit.minutes <= 600))
    && (habit.minimum === null || text(habit.minimum, 1, 80))
    && ['off', 'ask', 'plan'].includes(habit.support)
    && timestamp(habit.createdAt) && timestamp(habit.updatedAt) && isDate(habit.createdOn)
    && (habit.archivedAt === null ? habit.archivedOn === null : timestamp(habit.archivedAt) && isDate(habit.archivedOn))
    && Number.isInteger(habit.revision) && habit.revision >= 1
    && Array.isArray(habit.targets) && habit.targets.length > 0
    && habit.targets.every((entry, index) => entry && isDate(entry.from) && weekFor(entry.from).start === entry.from
      && target(entry.weeklyTarget, habit.kind) && (index === 0 || habit.targets[index - 1].from < entry.from));
}

function validate(state) {
  if (!Array.isArray(state.habits) || !Array.isArray(state.events)
      || !state.checkins || typeof state.checkins !== 'object' || Array.isArray(state.checkins)
      || !state.ops || typeof state.ops !== 'object' || Array.isArray(state.ops)
      || state.habits.some((h) => !validHabit(h))
      || new Set(state.habits.map((h) => h.id)).size !== state.habits.length
      || Object.values(state.checkins).some((days) => !Array.isArray(days) || days.some((d, i) => !isDate(d) || (i > 0 && days[i - 1] >= d)))
      || state.events.some((event) => !event || typeof event.id !== 'string' || typeof event.habitId !== 'string')
      || Object.values(state.ops).some((op) => !op || typeof op.habitId !== 'string' || !Number.isFinite(Date.parse(op.at)))) {
    throw new StateFileError('state_corrupt', 'habits state has an invalid shape');
  }
  return state;
}

export function createHabitStore({ dir, now = () => Date.now() } = {}) {
  const file = join(dir, 'habits.json');
  const backups = join(dir, 'habits-backups');
  const json = createJsonFile({ file, initial: () => ({ habits: [], checkins: {}, events: [], ops: {} }) });

  function guarded(fn) {
    try { return fn(); } catch (error) {
      if (error instanceof Unchanged) return error.result;
      if (error instanceof BridgeError) throw error;
      if (error instanceof StateFileError || typeof error.code === 'string') {
        throw new BridgeError(500, error instanceof StateFileError ? error.code : 'state_unwritable', 'habits storage is unavailable');
      }
      throw error;
    }
  }

  function backup() {
    if (!existsSync(file)) return;
    mkdirSync(backups, { recursive: true, mode: 0o700 });
    chmodSync(backups, 0o700);
    const destination = join(backups, `habits-${tokyoDate(now())}.json`);
    try {
      copyFileSync(file, destination, constants.COPYFILE_EXCL);
      chmodSync(destination, 0o600);
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
    const names = readdirSync(backups).filter((name) => BACKUP_NAME.test(name)).sort().reverse();
    for (const name of names.slice(30)) unlinkSync(join(backups, name));
  }

  return {
    file,
    read: () => guarded(() => validate(json.read())),
    mutate(fn) {
      return guarded(() => json.mutate((state) => {
        validate(state);
        const before = JSON.stringify(state);
        const result = fn(state);
        if (before === JSON.stringify(state)) throw new Unchanged(result);
        for (const [key, op] of Object.entries(state.ops)) {
          if (now() - Date.parse(op.at) >= OP_RETENTION_MS) delete state.ops[key];
        }
        // This runs under createJsonFile's lock, after a valid mutation and
        // before its atomic replacement, so failed/no-op requests copy nothing.
        backup();
        return result;
      }));
    },
  };
}
