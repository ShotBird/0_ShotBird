#!/bin/bash
# 사용: autolaunch.sh <min>   (메인 세션이 백그라운드로 띄운다)
# 2분마다 이번 라운드(번호 ≥ min)의 frontier를 herdr 탭으로 띄운다.
# 범위 안에 열린 이슈가 skip·사람 대기열(held_ids) 말고는 하나도 없으면 끝난다.
. "$(dirname "$0")/lib.sh"
require_herdr
MIN="${1:?min issue number}"
log "autolaunch start min=$MIN"
# 세션이 close 때 붙이는 검증 큐 라벨 (없으면 만든다)
gh label create verify:browser --repo "$GH_REPO" --color FBCA04 --description "브라우저 확인만 남은 채 닫힘 — 메인이 verify 큐로 확인" > /dev/null 2>&1
MAX="${ORCH_MAX_SESSIONS:-6}"   # 동시에 떠 있는 병렬 세션(t<키>) 상한 — 세션마다 메모리 1 GB 안팎(2026-09-27 20개에 여유 6.8 GB)
MIN_FREE_GB="${ORCH_MIN_FREE_GB:-0}"   # 여유 물리 메모리(GB)가 이 값보다 적으면 새 세션을 띄우지 않는다(0 = 끔) — 메모리가 먼저 바닥나는 PC용
free_gb() { command -v powershell >/dev/null 2>&1 || return 0; powershell -NoProfile -Command "[math]::Floor((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB)" 2>/dev/null | tr -d '\r'; }
live_sessions() { herdr agent list 2>/dev/null | python -c "
import sys,json,re
print(sum(1 for a in json.load(sys.stdin)['result']['agents'] if re.fullmatch(r't\d+r?',a.get('name') or '')))" | tr -d '\r'; }
while :; do
  for n in $(frontier "$MIN" | prioritize); do   # .orchestra/priority 번호가 먼저
    cur=$(live_sessions); [ -z "$cur" ] && cur=0
    if [ "$cur" -ge "$MAX" ]; then log "autolaunch: 세션 $cur/$MAX — 상한, 다음 주기에"; break; fi
    if [ "$MIN_FREE_GB" -gt 0 ]; then
      fg=$(free_gb)
      if [ -n "$fg" ] && [ "$fg" -lt "$MIN_FREE_GB" ]; then log "autolaunch: 여유 메모리 ${fg} GB < ${MIN_FREE_GB} GB — 새 세션 보류, 다음 주기에"; break; fi
    fi
    spawn_ticket "$n"
  done
  # gh 실패(망·API 일시 오류)의 빈 출력을 "열린 티켓 0"으로 읽지 않는다 — 2026-09-24 열린 티켓 3개를 두고 done으로 끝난 사건
  all=$(in_scope open "$MIN") || { log "autolaunch: gh 조회 실패 — 다음 주기에 재시도"; sleep 120; continue; }
  left=$(printf '%s\n' "$all" | grep -vxF -f <(held_ids))
  [ -z "$left" ] && { log "autolaunch done min=$MIN"; tail -20 "$LOG"; exit 0; }
  sleep 120
done
