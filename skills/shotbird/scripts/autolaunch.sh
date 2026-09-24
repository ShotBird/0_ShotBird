#!/bin/bash
# 사용: autolaunch.sh <min>   (메인 세션이 백그라운드로 띄운다)
# 2분마다 이번 라운드(번호 ≥ min)의 frontier를 herdr 탭으로 띄운다.
# 범위 안에 열린 이슈가 skip 목록 말고는 하나도 없으면 끝난다.
. "$(dirname "$0")/lib.sh"
require_herdr
MIN="${1:?min issue number}"
log "autolaunch start min=$MIN"
# 세션이 close 때 붙이는 검증 큐 라벨 (없으면 만든다)
gh label create verify:browser --repo "$GH_REPO" --color FBCA04 --description "브라우저 확인만 남은 채 닫힘 — 메인이 verify 큐로 확인" > /dev/null 2>&1
while :; do
  for n in $(frontier "$MIN"); do spawn_ticket "$n"; done
  left=$(in_scope open "$MIN" | grep -vxF -f "$STATE/skip")
  [ -z "$left" ] && { log "autolaunch done min=$MIN"; tail -20 "$LOG"; exit 0; }
  sleep 120
done
