// Owner notifications from the Bridge to the LAA app. Sessions, tasks and the
// calendar all call this one entry point so delivery and dedupe rules stay in
// one place. Until a delivery path is wired in, nothing is sent and the caller
// learns why.
export async function notifyOwner({ kind, title, body, deepLink, dedupeKey } = {}) {
  void kind; void title; void body; void deepLink; void dedupeKey;
  return { delivered: false, reason: 'not_configured' };
}
