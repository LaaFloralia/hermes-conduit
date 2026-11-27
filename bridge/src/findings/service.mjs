import { BridgeError, badRequest } from '../errors.mjs';

const LIST_STATUS = ['open', 'delegated', 'done'];
const countsFor = (rows, labels) => Object.fromEntries(labels.map((status) => [status, rows.filter((row) => row.status === status).length]));

export function createFindingService({ store, sessionStore = null, refFor = null, observe = null }) {
  let observed;
  function reconcile(rows = store.all()) {
    if (!observe) return;
    const items = rows.filter((row) => row.status !== 'dismissed').map((row) => ({
      key: row.id, title: row.title, createdAt: row.createdAt, external: { sessionId: row.source.sessionId },
    }));
    const snapshot = JSON.stringify(items);
    if (snapshot !== observed && observe('finding', items) != null) observed = snapshot;
  }
  function view(row, local) {
    const { requestId, ...visible } = row;
    return { ...visible,
      ref: row.status === 'dismissed' ? null : refFor?.('finding', row.id) ?? null,
      sourceRef: row.source.sessionId ? refFor?.('session', row.source.sessionId) ?? null : null,
      stale: store.isStale(row), ...(local ? { requestId } : {}),
    };
  }
  function result(row, local) {
    if (!local) reconcile();
    return view(row, local);
  }
  return {
    reconcile,
    add(body, imageInputs) {
      const agent = body.source?.sessionId;
      const session = agent && sessionStore?.all().find((row) => row.id === agent || row.delegate?.sessionId === agent);
      return view(store.add({ ...body, source: { sessionId: session?.id ?? agent, name: body.source?.name ?? session?.name } }, imageInputs), true);
    },
    list({ status = 'all', local = false } = {}) {
      if (status !== 'all' && !LIST_STATUS.includes(status)) throw badRequest('finding_invalid', 'status: open・delegated・done・allのいずれかを指定してください。');
      const rows = store.all();
      if (!local) reconcile(rows);
      const items = rows.filter((row) => status === 'all' ? LIST_STATUS.includes(row.status) : row.status === status)
        .reverse().sort((a, b) => b.createdAt.localeCompare(a.createdAt)).map((row) => view(row, local));
      return local ? { items } : { items, counts: countsFor(rows, LIST_STATUS) };
    },
    get(id, { local = false } = {}) {
      const rows = store.all();
      if (!local) reconcile(rows);
      const row = rows.find((r) => r.id === id);
      if (!row) throw new BridgeError(404, 'finding_not_found', '気づきが見つかりません。');
      return view(row, local);
    },
    delegate: (id, { local = false } = {}) => result(store.delegate(id), local),
    dismiss: (id, { local = false } = {}) => result(store.dismiss(id), local),
    pickup: (id, plan) => view(store.pickup(id, plan), true),
    done: (id, message) => view(store.done(id, message), true),
    image: (id, imgId, size) => store.image(id, imgId, size),
    stats() {
      const rows = store.all();
      return { ...countsFor(rows, [...LIST_STATUS, 'dismissed']), stale: rows.filter(store.isStale).length };
    },
  };
}
