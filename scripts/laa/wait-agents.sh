#!/bin/zsh
# Wait for Paseo agents. `any`: exit as soon as one is idle. `all`: wait until all are idle, then print each one's last message.
mode="$1"; shift; ids=("$@")
if [[ ( $mode != any && $mode != all ) || ${#ids} -eq 0 ]]; then
  echo "usage: wait-agents.sh any|all <short-id>..." >&2; exit 2
fi
matching() {
  paseo ls --json 2>/dev/null | python3 -c '
import json,sys
idle=sys.argv[1]=="idle"; w=set(sys.argv[2:]); d=json.load(sys.stdin)
print(" ".join(a["shortId"] for a in d if a["shortId"] in w and (a["status"]=="idle")==idle))' "$1" "${ids[@]}"
}
if [[ $mode == any ]]; then
  while :; do
    idle=$(matching idle)
    [[ -n $idle ]] && { echo "idle: $idle"; exit 0; }
    sleep 60
  done
fi
while [[ -n $(matching busy) ]]; do sleep 45; done
for id in "${ids[@]}"; do
  echo "== $id"
  paseo logs $id 2>/dev/null | awk '/\[Agent message\]/{buf=""} {buf=buf"\n"$0} END{print buf}' | grep -vE '^\[(Shell|Terminal|Edit|Compacted|User|Read|Search|Thought)\]' | grep -v '^$' | tail -4 | cut -c1-300
done
