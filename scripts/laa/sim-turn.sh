#!/bin/zsh
# Wait until no simulator is running, then give the named worker the simulator turn.
id="$1"; msg="$2"
while [ "$(pgrep -x launchd_sim | wc -l | tr -d ' ')" != 0 ]; do sleep 30; done
paseo send "$id" --no-wait --prompt "$msg" >/dev/null 2>&1 && echo "turn given to $id at $(date +%H:%M)"
