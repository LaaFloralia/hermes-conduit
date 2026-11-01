// Synthetic files only; compiles and runs a macOS CLI, without a simulator.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const temporary = mkdtempSync(join(tmpdir(), 'laa-drive-offline-fixture-'));
try {
  const binary = join(temporary, 'fixture');
  execFileSync('swiftc', ['-swift-version', '5', '-D', 'LAA_BUILD', '-parse-as-library',
    join(root, 'Conduit/LAA/Drive/LAADriveOfflineStore.swift'),
    join(root, 'Conduit/LAA/Drive/LAADriveOfflineAccess.swift'),
    join(here, 'drive-offline-test.swift'), '-o', binary], { stdio: 'inherit' });
  execFileSync(binary, [join(temporary, 'data')], { stdio: 'inherit' });
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
