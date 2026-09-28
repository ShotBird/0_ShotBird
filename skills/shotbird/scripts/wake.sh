#!/bin/bash
# 사용: wake.sh <min>   (메인 세션이 백그라운드로 띄운다 — 끝나면 메인이 깨어난다)
# 이번 라운드(번호 ≥ min)에서 새로 닫힌, 아직 메인이 취합하지 않은 이슈가 생기면 번호를 출력하고 끝난다.
# 메인은 취합한 번호를 .orchestra/consolidated에 적고 wake.sh를 다시 띄운다.
# 그 밖에 깨우는 것: 사람 대기열 하루 1회 요약(human queue digest) · 받은편지함 새 파일(inbox, ORCH_INBOX_DIR 설정 시) · 교차 리뷰 시점(cross-review due) ·
#   병합 큐 막힘(merge queue stuck) · 받을 세션 없는 병합 반려(merge rejected, no session) · 정체(stalled).
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
  # 받은편지함 폴더(선택, ORCH_INBOX_DIR — 리포 기준 상대 경로 또는 절대 경로)에 새 파일이 생김.
  #   메인은 그 파일을 리포 규약대로 처리(예: 반입 번들 검사 → 인입 티켓)하고 wake를 다시 띄운다. 본 파일은 .orchestra/inbox_seen에 적혀 다시 알리지 않는다.
  if [ -n "${ORCH_INBOX_DIR:-}" ]; then
    idir="$ORCH_INBOX_DIR"; case "$idir" in /*|[A-Za-z]:*) ;; *) idir="$REPO/$idir" ;; esac
    touch "$STATE/inbox_seen"
    if [ -d "$idir" ]; then
      newf=$(find "$idir" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort | grep -vxF -f "$STATE/inbox_seen")
      if [ -n "$newf" ]; then
        printf '%s\n' "$newf" >> "$STATE/inbox_seen"
        echo "inbox ($ORCH_INBOX_DIR):"; printf '%s\n' "$newf"; exit 0
      fi
    fi
  fi
  # 합쳐지지 않은 채 닫힌 세션 — autoclose가 "브랜치 … main에 없음"을 남긴 키(세션이 push를 빠뜨림, 2026-09-27 #577).
  #   메인은 그 브랜치의 커밋을 main에 다시 합치는 후속 작업(<번호>r)을 띄운다. 같은 키는 한 번만(.orchestra/unmerged_reported).
  touch "$STATE/unmerged_reported"
  um=$(grep -o 't[0-9]*r\? 브랜치 orch/t[0-9]*r\? 는 main에 없음' "$LOG" 2>/dev/null | awk '{print $1}' | sort -u | grep -vxF -f "$STATE/unmerged_reported")
  if [ -n "$um" ]; then
    printf '%s\n' $um >> "$STATE/unmerged_reported"
    echo "closed but not merged (branch kept):"; printf '%s\n' $um; exit 0
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
  # 병합 큐가 막힘 — 대기 항목이 있는데 병합기(merge.sh)가 안 돌거나, 가장 오래된 대기가 ORCH_MERGE_STALE_MIN(기본 30)분을 넘김.
  #   큐에 올린 세션은 idle이어도 정체로 치지 않으므로(아래) 이것이 대신 막힘을 잡는다. 같은 (종류, 가장 오래된 항목)은 한 번만(.orchestra/merge_alarm).
  pending=$(queue_pending)
  if [ -n "$pending" ]; then
    read -r okey osha oep <<< "$(printf '%s\n' "$pending" | head -1)"
    alarm=""
    if ! merger_alive; then alarm="merger-down"
    elif [ "${oep:-0}" -gt 0 ] && [ $(( $(date +%s) - oep )) -ge $(( ${ORCH_MERGE_STALE_MIN:-30} * 60 )) ]; then alarm="merge-slow"; fi
    if [ -n "$alarm" ] && [ "$(cat "$STATE/merge_alarm" 2>/dev/null)" != "$alarm $okey $osha" ]; then
      echo "$alarm $okey $osha" > "$STATE/merge_alarm"
      echo "merge queue stuck ($alarm): 대기 $(printf '%s\n' "$pending" | wc -l)건, 가장 오래된 #$okey ${osha:0:9}"
      [ "$alarm" = merger-down ] && echo "  병합기가 안 돈다 — merge.sh 기동(ORCH_MERGE_TEST 등 설정은 SKILL.md 병합 절)"
      exit 0
    fi
  fi
  if [ "${HERDR_ENV:-}" = 1 ]; then
    stalled=""
    agents=$(herdr agent list | python -c "
import sys,json,re
for a in json.load(sys.stdin)['result']['agents']:
    n=a.get('name') or ''
    if re.fullmatch(r't\d+r?',n): print(n,a.get('agent_status'))" | tr -d '\r')
    while read -r name st; do
      [ -z "$name" ] && continue
      key=${name#t}; [ "$key" != "${key%r}" ] && continue          # 후속 작업(<번호>r)은 티켓 상태로 판정 불가
      grep -qx "$key" "$STATE/stalled_reported" && continue
      printf '%s\n' "$pending" | awk -v k="$key" '$1 == k { f = 1 } END { exit !f }' && { idle[$key]=0; continue; }   # 큐에 올리고 병합 대기 = 정상 idle
      if { [ "$st" = idle ] || [ "$st" = done ]; } && [ "$(gh issue view "$key" --repo "$GH_REPO" --json state --jq .state)" = OPEN ]; then
        idle[$key]=$(( ${idle[$key]:-0} + 1 ))
        [ "${idle[$key]}" -ge 2 ] && stalled="$stalled $key"
      else idle[$key]=0; fi
    done <<< "$agents"
    if [ -n "$stalled" ]; then
      for k in $stalled; do echo "$k" >> "$STATE/stalled_reported"; done
      echo "stalled (idle, ticket open):"; printf '%s\n' $stalled; exit 0
    fi
    # 병합기가 반려했는데 받을 세션이 없음(탭이 닫힘) — 키의 마지막 등록이 rejected이고 t<키>가 없으면. 같은 (키, 커밋)은 한 번만.
    touch "$STATE/merge_rejected_reported"
    rj=$(queue_clean | awk -v st="$MSTATE" '
      BEGIN { while ((getline l < st) > 0) { split(l, f, " "); if (f[3] == "rejected") r[f[1] " " f[2]] = f[4] } }
      $0 ~ /^[0-9]+r? [0-9a-f]{40}/ { last[$1] = $2 }
      END { for (k in last) if ((k " " last[k]) in r) print k, last[k], r[k " " last[k]] }' \
      | while read -r k c why; do
          printf '%s\n' "$agents" | awk -v a="t$k" '$1 == a { f = 1 } END { exit !f }' && continue
          grep -qx "$k $c" "$STATE/merge_rejected_reported" && continue
          echo "$k $c $why"
        done)
    if [ -n "$rj" ]; then
      printf '%s\n' "$rj" | awk '{ print $1, $2 }' >> "$STATE/merge_rejected_reported"
      echo "merge rejected, no session (키 커밋 사유 — 이슈 코멘트에 자세히):"; printf '%s\n' "$rj"; exit 0
    fi
  fi
  sleep 120
done
