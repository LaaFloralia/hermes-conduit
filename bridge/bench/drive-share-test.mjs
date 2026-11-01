// Small local files only; no simulator, Drive account, or external share.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const temporary = mkdtempSync(join(tmpdir(), 'laa-drive-share-'));
try {
  const binary = join(temporary, 'fixture');
  execFileSync('swiftc', ['-swift-version', '5', '-D', 'LAA_BUILD', '-parse-as-library',
    join(root, 'Conduit/LAA/Drive/LAADriveShareFiles.swift'), join(here, 'drive-share-test.swift'),
    '-o', binary], { stdio: 'inherit' });
  execFileSync(binary, [join(temporary, 'data')], { stdio: 'inherit' });
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
