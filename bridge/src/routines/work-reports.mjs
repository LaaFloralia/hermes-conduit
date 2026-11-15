// The engine's completed schedule runs survive auto-archiving. Project those
// records through the same delivery entry as Hermes/Dots/Muse, without a model.
import { spawn } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pythonPath } from '../notify/index.mjs';

export function startWorkReports({ stateDir, intervalMs = 30_000, python = pythonPath(), log = () => {} }) {
  let active = null;
  const tick = () => {
    if (active || !python) return;
    const child = spawn(python, ['-I', fileURLToPath(new URL('./delivery.py', import.meta.url)),
      'scan-work', join(homedir(), '.local/state/laa-work/jobs.json'),
      join(stateDir, 'routine-work-start.json')], { stdio: ['ignore', 'pipe', 'ignore'] });
    active = child;
    let output = '';
    const timeout = setTimeout(() => child.kill(), 120_000);
    child.stdout.on('data', (chunk) => { if (output.length < 4096) output += chunk; });
    child.on('error', () => log('routine_work_unavailable'));
    child.on('close', (code) => {
      clearTimeout(timeout); active = null;
      try {
        if (code !== 0 || JSON.parse(output).errors?.length) log('routine_work_delivery_pending');
      } catch { log('routine_work_delivery_pending'); }
    });
  };
  tick();
  const timer = setInterval(tick, intervalMs);
  timer.unref?.();
  return () => { clearInterval(timer); };
}
