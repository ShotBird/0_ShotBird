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
# 상한에 세는 세션 = t<키> 중 '일하는' 것 — 끝내고 병합만 기다리는 세션(merge-queue 마지막 줄의 커밋이 merge-state에 아직 없고 idle/done)은 빼서
#   그동안 다음 티켓이 뜨게 한다(2026-10-26 — 상한 1에서 병합 대기 세션이 자리를 잡아 다음 티켓이 못 뜨는 틈).
live_sessions() { herdr agent list 2>/dev/null | ORCH_STATE="$STATE" python -c "
import sys,json,re,os
st=os.environ.get('ORCH_STATE','')
q={}; s=set()
try:
  for l in open(os.path.join(st,'merge-queue'),encoding='utf-8',errors='ignore'):
    p=l.split()
    if len(p)>=2: q[p[0]]=p[1]
  for l in open(os.path.join(st,'merge-state'),encoding='utf-8',errors='ignore'):
    p=l.split()
    if len(p)>=2: s.add((p[0],p[1]))
except Exception: pass
pend={k for k,c in q.items() if (k,c) not in s}
n=0
for a in json.load(sys.stdin)['result']['agents']:
  m=re.fullmatch(r't(\d+r?)',a.get('name') or '')
  if not m: continue
  if m.group(1) in pend and a.get('agent_status') in ('idle','done'): continue
  n+=1
print(n)" | tr -d '\r'; }
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
