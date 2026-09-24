#!/bin/bash
# 사용: wake.sh <min>   (메인 세션이 백그라운드로 띄운다 — 끝나면 메인이 깨어난다)
# 이번 라운드(번호 ≥ min)에서 새로 닫힌, 아직 메인이 취합하지 않은 이슈가 생기면 번호를 출력하고 끝난다.
# 메인은 취합한 번호를 .orchestra/consolidated에 적고 wake.sh를 다시 띄운다.
. "$(dirname "$0")/lib.sh"
MIN="${1:?min issue number}"
while :; do
  new=$(in_scope closed "$MIN" | grep -vxF -f "$STATE/consolidated")
  [ -n "$new" ] && { echo "closed, not consolidated:"; echo "$new"; exit 0; }
  sleep 120
done
