#!/usr/bin/env python3
"""Compile the real widget bundle declaration under both build flags."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'ConduitWidgets' / 'LauncherWidgets.swift').read_text()
start = source.index('struct ConduitWidgets: WidgetBundle')
opening = source.index('{', start)
depth = 0
for index in range(opening, len(source)):
    depth += (source[index] == '{') - (source[index] == '}')
    if depth == 0:
        bundle = source[start:index + 1]
        break
else:
    raise ValueError('WidgetBundle declaration is incomplete')

stub = r'''
protocol Widget { var kinds: [String] { get } }
struct GroupWidget: Widget { var kinds: [String] }
@resultBuilder enum WidgetBuilder {
    static func buildBlock(_ widgets: any Widget...) -> GroupWidget {
        GroupWidget(kinds: widgets.flatMap(\.kinds))
    }
}
protocol WidgetBundle { associatedtype Body: Widget; @WidgetBuilder var body: Body { get } }
struct NativeLauncherWidget: Widget { let kinds = ["native"] }
struct CharacterLauncherWidget: Widget { let kinds = ["character"] }
struct LAAEmployeeWidget: Widget { let kinds = ["employee"] }
struct HermesTurnLiveActivity: Widget { let kinds = ["liveActivity"] }
'''
runner = r'''
@main struct Check {
    static func main() {
        let kinds = ConduitWidgets().body.kinds
        #if LAA_BUILD
        precondition(kinds == ["employee", "liveActivity"], "Unexpected LAA registrations: \(kinds)")
        #else
        precondition(kinds == ["native", "character", "liveActivity"], "Unexpected upstream registrations: \(kinds)")
        #endif
        print("Widget registrations: \(kinds.joined(separator: ", "))")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='laa-widget-registration-') as tmp:
    source_file = Path(tmp) / 'check.swift'
    source_file.write_text(stub + '\n' + bundle + '\n' + runner)
    binary = str(Path(tmp) / 'check')
    for flags in (['-D', 'LAA_BUILD'], []):
        subprocess.run(['swiftc', '-parse-as-library', *flags, str(source_file), '-o', binary], check=True)
        subprocess.run([binary], check=True)
