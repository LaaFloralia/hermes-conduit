// Compile the actual Work catalog cache with a controlled Bridge transport.
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
const root = new URL('../../', import.meta.url);
const source = readFileSync(new URL('Conduit/LAA/Work/LAAWorkModelSelection.swift', root), 'utf8');
const cache = source.slice(source.indexOf('@MainActor enum LAAWorkOptionsStore'), source.lastIndexOf('#endif'));
const dir = mkdtempSync(join(tmpdir(), 'work-options-cache-'));
try {
  const file = join(dir, 'main.swift');
  writeFileSync(file, `import Foundation
struct LAAWorkSessionOptions { let id: Int }
@MainActor final class LAABridgeSession {
    var address = "fixture"
    var deviceID: String? = "device"
    var revision = 0
    var calls = 0
    var fail = false
    func read(_ path: String) async throws -> LAAWorkSessionOptions {
        precondition(path == "/v1/session-options?catalogOnly=true")
        calls += 1
        try await Task.sleep(for: .milliseconds(30))
        if fail { throw CancellationError() }
        return .init(id: calls)
    }
}
${cache}
@main struct Check {
    @MainActor static func main() async throws {
        let bridge = LAABridgeSession()
        async let a = LAAWorkOptionsStore.read(bridge)
        async let b = LAAWorkOptionsStore.read(bridge)
        let pair = try await (a, b)
        precondition(pair.0.id == pair.1.id && bridge.calls == 1)
        _ = try await LAAWorkOptionsStore.read(bridge)
        precondition(bridge.calls == 1)
        _ = try await LAAWorkOptionsStore.read(bridge, force: true)
        precondition(bridge.calls == 2)
        bridge.revision += 1
        _ = try await LAAWorkOptionsStore.read(bridge)
        precondition(bridge.calls == 3)
        bridge.fail = true
        do { _ = try await LAAWorkOptionsStore.read(bridge, force: true); fatalError("failure lost") }
        catch is CancellationError {}
        bridge.fail = false
        _ = try await LAAWorkOptionsStore.read(bridge, force: true)
        precondition(bridge.calls == 5)
        let stale = Task { try await LAAWorkOptionsStore.read(bridge, force: true) }
        try await Task.sleep(for: .milliseconds(5))
        bridge.revision += 1
        do { _ = try await stale.value; fatalError("changed identity accepted") }
        catch is CancellationError {}
        print("Work catalog cache: coalescing, cache hit, force, identity, failure recovery passed")
    }
}
`);
  for (const args of [['swiftc', '-parse-as-library', '-swift-version', '6', file, '-o', join(dir, 'check')], [join(dir, 'check')]]) {
    const result = spawnSync(args[0], args.slice(1), { stdio: 'inherit' });
    if (result.status !== 0) process.exitCode = result.status ?? 1;
    if (process.exitCode) break;
  }
} finally { rmSync(dir, { recursive: true, force: true }); }
