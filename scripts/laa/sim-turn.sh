#!/bin/zsh
# Wait until this project's simulators are shut down, then give the named worker the simulator turn.
# Simulators used by other work (for example the voice keyboard) are not counted.
id="$1"; msg="$2"
devices=(DFFD3966-F54E-4C7A-A161-59201C7EA105 228F6BE7-98B2-4AF6-861F-F76BC8CA0DE7)
booted() { DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl list devices booted | grep -c -F -e "$devices[1]" -e "$devices[2]"; }
while [ "$(booted)" != 0 ]; do sleep 30; done
paseo send "$id" --no-wait --prompt "$msg" >/dev/null 2>&1 && echo "turn given to $id at $(date +%H:%M)"
