#!/bin/bash
# 사용: wake.sh <min>   (메인 세션이 백그라운드로 띄운다 — 끝나면 메인이 깨어난다)
# 이번 라운드(번호 ≥ min)에서 새로 닫힌, 아직 메인이 취합하지 않은 이슈가 생기면 번호를 출력하고 끝난다.
# 메인은 취합한 번호를 .orchestra/consolidated에 적고 wake.sh를 다시 띄운다.
. "$(dirname "$0")/lib.sh"
MIN="${1:?min issue number}"
# 정체 = 오케스트라 세션(t<번호>)이 idle/done인데 티켓은 열려 있음 → 연속 2회(≈4분)면 보고. 같은 키는 한 번만(.orchestra/stalled_reported).
touch "$STATE/stalled_reported"; declare -A idle
while :; do
  new=$(gh issue list --repo "$GH_REPO" --state closed --limit 300 --json number,labels \
    --jq ".[] | select(.number>=$MIN and ([.labels[].name]|index(\"wayfinder:map\")|not)) | .number" \
    | grep -vxF -f "$STATE/consolidated")
  [ -n "$new" ] && { echo "closed, not consolidated:"; echo "$new"; exit 0; }
  if [ "${HERDR_ENV:-}" = 1 ]; then
    stalled=""
    while read -r name st; do
      [ -z "$name" ] && continue
      key=${name#t}; [ "$key" != "${key%r}" ] && continue          # 후속 작업(<번호>r)은 티켓 상태로 판정 불가
      grep -qx "$key" "$STATE/stalled_reported" && continue
      if { [ "$st" = idle ] || [ "$st" = done ]; } && [ "$(gh issue view "$key" --repo "$GH_REPO" --json state --jq .state)" = OPEN ]; then
        idle[$key]=$(( ${idle[$key]:-0} + 1 ))
        [ "${idle[$key]}" -ge 2 ] && stalled="$stalled $key"
      else idle[$key]=0; fi
    done <<< "$(herdr agent list | python -c "
import sys,json,re
for a in json.load(sys.stdin)['result']['agents']:
    n=a.get('name') or ''
    if re.fullmatch(r't\d+r?',n): print(n,a.get('agent_status'))" | tr -d '\r')"
    if [ -n "$stalled" ]; then
      for k in $stalled; do echo "$k" >> "$STATE/stalled_reported"; done
      echo "stalled (idle, ticket open):"; printf '%s\n' $stalled; exit 0
    fi
  fi
  sleep 120
done
