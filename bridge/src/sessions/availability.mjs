// Which Work providers can start a session now, as the LAA Work engine reports it
// (`laa-work provider ls --json`). The session options stay synchronous: the answer is read in
// the background and kept for a short while, and until the first one nothing is marked.
// A provider that cannot run stays in the list with its reason on the label (a Dot whose
// contract ended, Muse before its contract), so choosing it is never a silent wait.

import { execFile } from 'node:child_process';
import { dirname } from 'node:path';

export function providerAvailability({ bin, ttlMs = 30_000, timeoutMs = 10_000, run = execFile, now = Date.now } = {}) {
  let byId = new Map();
  let at = -Infinity;
  let loading = null;
  // launchd starts the Bridge with a minimal PATH; the CLI's shebang runs `node`.
  const path = [dirname(process.execPath), '/opt/homebrew/bin', '/usr/local/bin', process.env.PATH].filter(Boolean).join(':');

  function refresh() {
    if (!bin) return Promise.resolve();
    loading ??= new Promise((resolve) => {
      run(bin, ['provider', 'ls', '--json'], { timeout: timeoutMs, maxBuffer: 256 * 1024, env: { ...process.env, PATH: path } }, (error, stdout) => {
        loading = null;
        if (!error) {
          try {
            const list = JSON.parse(stdout);
            if (Array.isArray(list)) {
              byId = new Map(list.filter((p) => p && typeof p.id === 'string').map((p) => [p.id, p]));
              at = now();
            }
          } catch { /* keep the last answer */ }
        }
        resolve();
      });
    });
    return loading;
  }

  return {
    // The engine's last word on one provider, or null before it has answered.
    get(provider) {
      if (now() - at > ttlMs) void refresh();
      return byId.get(provider) ?? null;
    },
    refresh,
  };
}

// A profile whose provider cannot take a session now keeps its place in the list and says why.
export function withAvailability(profile, state) {
  // The free GUI cannot stand in for a verified Muse Code session provider.
  if (profile.provider === 'muse' && state?.available !== true && state?.available !== false) {
    state = { available: false, reason: 'Muse Code availability has not been verified', reasonShort: '接続未確認' };
  }
  if (!state || state.available !== false) return profile;
  const short = profile.provider === 'muse' && state.reason === 'Muse Code CLI is not installed' ? 'Muse Code未導入' : typeof state.reasonShort === 'string' && state.reasonShort.trim() ? state.reasonShort.trim() : null;
  return {
    ...profile,
    label: `${profile.label}（${short ? `${short}のため使えません` : '今は使えません'}）`,
    available: false,
    unavailableReason: typeof state.reason === 'string' ? state.reason : null,
    ...(profile.provider === 'muse' ? { usageNote: '無料MuseはChatの「薬用石鹸」で使います。\n公開情報のみ・道具なし・直列・遅延あり。\nSessionごとの履歴分離には未対応です。' } : {}),
  };
}
