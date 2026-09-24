#!/bin/bash
# 사용: autoclose.sh   (메인 세션이 백그라운드로 띄운다)
# 오케스트라가 띄운 세션(t<키>)만 대상. 완료 = 이슈 CLOSED(키 "<번호>r"은 "#<번호>" 언급 커밋 존재)
# + 에이전트 idle/done이 1분 간격 연속 2회 → 그 탭을 닫는다. blocked(질문창)·working은 닫지 않는다.
# 도는 김에 advisor_sweep — Fable advisor가 실패한 idle 세션을 /advisor opus로(lib.sh).
# 남은 t<키> 세션이 없고 autolaunch가 끝났으면 종료.
. "$(dirname "$0")/lib.sh"
require_herdr
declare -A seen
log "autoclose start"
while :; do
  rows=$(herdr agent list | python -c "
import sys,json,re
for a in json.load(sys.stdin)['result']['agents']:
    n=a.get('name') or ''
    if re.fullmatch(r't\d+r?',n): print(n,a.get('agent_status'),a.get('tab_id'))" | tr -d '\r')
  if [ -z "$rows" ] && grep "autolaunch " "$LOG" | tail -1 | grep -q "autolaunch done"; then
    log "autoclose done"; exit 0
  fi
  while read -r name st tab; do
    [ -z "$name" ] && continue
    advisor_sweep "$name" "$st"
    key=${name#t}; num=${key%r}
    if [ "$key" != "$num" ]; then
      [ -n "$(git -C "$REPO" log --oneline -E --grep="#$num([^0-9]|$)" -1)" ] && fin=y || fin=
    else
      [ "$(state_of "$num")" = CLOSED ] && fin=y || fin=
    fi
    if [ "$fin" = y ] && { [ "$st" = idle ] || [ "$st" = done ]; }; then
      label=$(herdr tab get "$tab" | python -c "import sys,json;print(json.load(sys.stdin)['result']['tab'].get('label',''))" | tr -d '\r')
      case "$label" in *"#$key") ;; *) continue ;; esac   # 오케스트라가 만든 탭만
      if [ -n "${seen[$name]}" ]; then
        herdr tab close "$tab" > /dev/null && log "closed $name ($label)"
        unset "seen[$name]"
      else seen[$name]=1; fi
    else unset "seen[$name]"; fi
  done <<< "$rows"
  sleep 60
done
