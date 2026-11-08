// Exercise the real AVPlayer on macOS with a small local fixture, not a simulator.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const temporary = mkdtempSync(join(tmpdir(), 'laa-native-playback-test-'));
try {
  const binary = join(temporary, 'fixture');
  execFileSync('swiftc', ['-swift-version', '5', '-D', 'LAA_BUILD', '-parse-as-library',
    join(root, 'Conduit/LAA/Drive/LAADrivePlaybackState.swift'),
    join(root, 'Conduit/LAA/Drive/LAADrivePlaybackCoordinator.swift'),
    join(here, 'drive-native-playback-test.swift'), '-o', binary], { stdio: 'inherit' });
  execFileSync(binary, [join(root, 'docs/laa/assets/staff/monet/monet-idle-512.mov')], { stdio: 'inherit' });
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
