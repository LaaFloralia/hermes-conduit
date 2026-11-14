export const TIME_ZONE = 'Asia/Tokyo';
const DAY = 86_400_000;

export function tokyoDate(time) {
  return new Date(Number(time) + 9 * 60 * 60 * 1000).toISOString().slice(0, 10);
}

export function isDate(value) {
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)
    && Number.isFinite(Date.parse(`${value}T00:00:00Z`))
    && new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) === value;
}

export function addDays(date, count) {
  return new Date(Date.parse(`${date}T00:00:00Z`) + count * DAY).toISOString().slice(0, 10);
}

export function weekFor(date) {
  const weekday = new Date(`${date}T00:00:00Z`).getUTCDay();
  const start = addDays(date, -((weekday + 6) % 7));
  return { start, end: addDays(start, 6), days: Array.from({ length: 7 }, (_, i) => addDays(start, i)) };
}
