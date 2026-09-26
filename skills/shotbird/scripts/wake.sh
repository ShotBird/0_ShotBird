#!/bin/bash
# 사용: wake.sh <min>   (메인 세션이 백그라운드로 띄운다 — 끝나면 메인이 깨어난다)
# 이번 라운드(번호 ≥ min)에서 새로 닫힌, 아직 메인이 취합하지 않은 이슈가 생기면 번호를 출력하고 끝난다.
# 메인은 취합한 번호를 .orchestra/consolidated에 적고 wake.sh를 다시 띄운다.
# 그 밖에 깨우는 것: 사람 대기열 하루 1회 요약(human queue digest) · 교차 리뷰 시점(cross-review due).
. "$(dirname "$0")/lib.sh"
MIN="${1:?min issue number}"
# 정체 = 오케스트라 세션(t<번호>)이 idle/done인데 티켓은 열려 있음 → 연속 2회(≈4분)면 보고. 같은 키는 한 번만(.orchestra/stalled_reported).
touch "$STATE/stalled_reported"; declare -A idle
while :; do
  new=$(gh issue list --repo "$GH_REPO" --state closed --limit 300 --json number,labels \
    --jq ".[] | select(.number>=$MIN and ([.labels[].name]|index(\"wayfinder:map\")|not)) | .number" \
    | grep -vxF -f "$STATE/consolidated")
  [ -n "$new" ] && { echo "closed, not consolidated:"; echo "$new"; exit 0; }
  # 사람 대기열 요약 — 하루 1회(.orchestra/human_digest_date). 메인은 사용자에게 기한 지난 항목을 알린다.
  if [ -s "$STATE/human-queue.tsv" ] && [ "$(cat "$STATE/human_digest_date" 2>/dev/null)" != "$(date +%F)" ]; then
    date +%F > "$STATE/human_digest_date"; echo "human queue digest:"; human_digest; exit 0
  fi
  # 교차 리뷰 — 마지막 리뷰 표식(.orchestra/review_mark = 커밋) 이후 main 커밋이 ORCH_REVIEW_EVERY(기본 60)개를 넘으면 알린다.
  #   메인은 그 범위(git diff <표식>..origin/main)의 교차 리뷰 research 티켓을 만들고 표식을 origin/main으로 옮긴다.
  git -C "$REPO" fetch -q origin 2>/dev/null
  [ -s "$STATE/review_mark" ] || git -C "$REPO" rev-parse origin/main > "$STATE/review_mark"
  mark=$(tr -d '\r\n' < "$STATE/review_mark")
  cnt=$(git -C "$REPO" rev-list --count "$mark..origin/main" 2>/dev/null || echo 0)
  if [ "$cnt" -ge "${ORCH_REVIEW_EVERY:-60}" ]; then
    echo "cross-review due: $mark..$(git -C "$REPO" rev-parse --short origin/main) ($cnt commits)"; exit 0
  fi
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
