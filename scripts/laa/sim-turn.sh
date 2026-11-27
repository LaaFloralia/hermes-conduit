#!/bin/zsh
# Abolished 2026-11-27 (owner decision); the body below is kept for a possible re-enable.
print -u2 "シミュレーター試験は2026-11-27に廃止されました（社長決定）。代わりに laa-app-gate pre hortensia --src <作業ツリー> を使ってください。"
exit 64
# Wait until this project's simulator is shut down, then give the named worker the simulator turn.
# Simulators used by other work (for example the voice keyboard) are not counted.
id="$1"; msg="$2"
device=DFFD3966-F54E-4C7A-A161-59201C7EA105
booted() { DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl list devices booted | grep -c -F -e "$device"; }
while [ "$(booted)" != 0 ]; do sleep 30; done
paseo send "$id" --no-wait --prompt "$msg" >/dev/null 2>&1 && echo "turn given to $id at $(date +%H:%M)"
