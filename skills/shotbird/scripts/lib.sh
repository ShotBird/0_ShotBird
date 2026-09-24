#!/bin/bash
# orchestra 공통 함수 — ../SKILL.md (/shotbird) 참조.
# 현재 디렉토리의 git 리포 = 대상. 이슈 = 그 리포의 GitHub Issues(gh CLI). herdr 안(HERDR_ENV=1)에서만 기동.
#
# 설정(환경변수, 모두 선택):
#   ORCH_AGENT_KIND   병렬 세션 에이전트 종류 (기본 claude)
#   ORCH_FIRST_INPUT  에이전트 기동 직후 첫 입력 (기본 "/advisor fable", 빈 문자열이면 생략)
#   ORCH_ADVISOR_FALLBACK  Fable advisor를 못 쓸 때 보낼 입력 (기본 "/advisor opus", 빈 문자열이면 폴백 안 함)
#   ORCH_WAYFINDER    결정 티켓에 쓰는 wayfinder 호출 (기본 "/mattpocock-skills:wayfinder")
# 리포별 세션 규칙 덮어쓰기: <리포>/.orchestra/rules-{decide,impl}.txt → <리포>/docs/agents/orchestra/rules-*.txt → 스킬 기본값

# Git Bash(MSYS)는 "/advisor fable"처럼 /로 시작하는 인자를 Windows 경로("C:/Program Files/Git/advisor fable")로 바꿔
# herdr에 넘긴다 — 슬래시 명령이 일반 프롬프트로 들어가던 결함(2026-09-24 발견). 이 스크립트들의 인자 변환을 끈다.
export MSYS_NO_PATHCONV=1

SKILL_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "git 리포 안에서 실행할 것"; exit 1; }
GH_REPO="$(cd "$REPO" && gh repo view --json nameWithOwner --jq .nameWithOwner)" || { echo "gh repo view 실패"; exit 1; }
STATE="$REPO/.orchestra"
mkdir -p "$STATE/extra"
touch "$STATE/launched" "$STATE/skip" "$STATE/consolidated"
LOG="$STATE/orchestra.log"
AGENT_KIND="${ORCH_AGENT_KIND:-claude}"
FIRST_INPUT="${ORCH_FIRST_INPUT-/advisor fable}"
ADVISOR_FALLBACK="${ORCH_ADVISOR_FALLBACK-/advisor opus}"
WAYFINDER="${ORCH_WAYFINDER:-/mattpocock-skills:wayfinder}"

log() { echo "$(date '+%m-%d %T') $*" >> "$LOG"; }
state_of() { gh issue view "$1" --repo "$GH_REPO" --json state --jq .state; }
blockers_of() { gh api "repos/$GH_REPO/issues/$1" --jq .issue_dependencies_summary.blocked_by; }
map_of() { gh api "repos/$GH_REPO/issues/$1/parent" --jq .number 2>/dev/null; }
kind_of() { gh issue view "$1" --repo "$GH_REPO" --json labels --jq '[.labels[].name|select(startswith("wayfinder:"))][0]//""|sub("wayfinder:";"")'; }
effort_of() { gh issue view "$1" --repo "$GH_REPO" --json labels --jq '[.labels[].name|select(startswith("effort:"))][0]//"ticket"|sub("effort:";"")'; }
rules_file() { # decide|impl
  local f
  for f in "$STATE/rules-$1.txt" "$REPO/docs/agents/orchestra/rules-$1.txt" "$SKILL_SCRIPTS/rules-$1.txt"; do
    [ -f "$f" ] && { echo "$f"; return; }
  done
}
require_herdr() { test "${HERDR_ENV:-}" = 1 || { echo "herdr 밖에서는 실행하지 않는다"; exit 1; }; }

# advisor_state <agent> — 화면 최근 텍스트로 advisor 상태 판정: ok | fail | unknown
#   fail = "/advisor …" 응답이 "Advisor set to"가 아님(Invalid advisor model 등), 또는 Fable advisor 호출 직후 줄에
#   한도·사용 불가·오류 문구. 그 뒤에 폴백 모델로 "Advisor set to"가 이미 찍혔으면 ok.
advisor_state() {
  herdr agent read "$1" --source recent-unwrapped 2>/dev/null | python -c "
import sys,re
L=[l.rstrip() for l in sys.stdin.buffer.read().decode('utf-8','replace').splitlines()]
st='unknown'
bad=re.compile(r'limit|quota|exceed|unavailable|not available|overloaded|error|fail|denied|invalid|\ud55c\ub3c4|\uc2e4\ud328|\uc0ac\uc6a9\ud560 \uc218 \uc5c6',re.I)
for i,l in enumerate(L):
    if re.search(r'Advisor set to',l): st='ok'
    elif re.search(r'^\s*\u276f\s*/advisor',l):
        nxt=' '.join(L[i+1:i+4])
        st='ok' if 'Advisor set to' in nxt else ('fail' if bad.search(nxt) else st)
    elif re.search(r'Advis\w*.*Fable',l) and bad.search(' '.join(L[i:i+3])) and not re.search(r'\u2714',' '.join(L[i:i+3])):
        st='fail'
print(st)" | tr -d '\r'
}

# set_first_input <agent> — 첫 입력(기본 /advisor fable). advisor 설정이 실패하면 ADVISOR_FALLBACK(기본 /advisor opus).
set_first_input() {
  herdr agent prompt "$1" "$FIRST_INPUT" --wait --timeout 30000 > /dev/null
  case "$FIRST_INPUT" in /advisor*) ;; *) return 0 ;; esac
  if [ -n "$ADVISOR_FALLBACK" ] && [ "$(advisor_state "$1")" != ok ]; then
    herdr agent prompt "$1" "$ADVISOR_FALLBACK" --wait --timeout 30000 > /dev/null
    log "$1 advisor fallback at launch → $ADVISOR_FALLBACK"
  fi
}

# advisor_sweep <agent> <status> — 도는 도중 Fable advisor가 한도·사용 불가로 실패한 세션을 폴백으로 바꾼다.
#   idle/done일 때만 보낸다(working·blocked에 입력 금지 — 질문창에 보낸 키는 답이 된다). 세션당 1회(.orchestra/advisor_fallback).
advisor_sweep() {
  local a="$1" st="$2"
  [ -n "$ADVISOR_FALLBACK" ] || return 0
  { [ "$st" = idle ] || [ "$st" = done ]; } || return 0
  grep -qx "$a" "$STATE/advisor_fallback" 2>/dev/null && return 0
  [ "$(advisor_state "$a")" = fail ] || return 0
  herdr agent prompt "$a" "$ADVISOR_FALLBACK" --wait --timeout 30000 > /dev/null
  echo "$a" >> "$STATE/advisor_fallback"; log "$a advisor fallback (Fable 사용 불가) → $ADVISOR_FALLBACK"
}

# spawn <key> <tab-label> <prompt>
#   key = 에이전트 이름 접미사(보통 이슈 번호; 닫힌 이슈의 후속 작업은 "<번호>r")
#   새 탭 1개 + 에이전트 t<key> → 첫 입력 → 작업 프롬프트
spawn() {
  local key="$1" label="$2" prompt="$3" tab pane
  grep -qx "$key" "$STATE/launched" && { log "skip $key (이미 띄움)"; return 0; }
  if herdr agent get "t$key" > /dev/null 2>&1; then
    echo "$key" >> "$STATE/launched"; log "skip $key (t$key 이미 실행 중)"; return 0
  fi
  echo "$key" >> "$STATE/launched"
  tab=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$REPO" --label "$label" --no-focus)
  pane=$(echo "$tab" | python -c "import sys,json;print(json.load(sys.stdin)['result']['root_pane']['pane_id'])" | tr -d '\r')
  if ! herdr agent start "t$key" --kind "$AGENT_KIND" --pane "$pane" --timeout 60000 > /dev/null; then
    log "t$key start FAIL"; return 1
  fi
  [ -n "$FIRST_INPUT" ] && set_first_input "t$key"
  if herdr agent prompt "t$key" "$prompt" > /dev/null; then log "t$key launched $pane ($label)"; else log "t$key prompt FAIL"; fi
}

# ticket_prompt <num> <decide|impl> [extra]
ticket_prompt() {
  local n="$1" mode="$2" extra="$3" map
  if [ "$mode" = impl ]; then
    printf '%s\n\n%s\n%s' "https://github.com/$GH_REPO/issues/$n 을 구현한다. 결정 출처는 이슈 본문에 링크된 결정 이슈의 resolution comment." "$(cat "$(rules_file impl)")" "$extra"
  else
    map=$(map_of "$n")
    if [ -n "$map" ]; then
      printf '%s\n\n%s\n%s' "$WAYFINDER https://github.com/$GH_REPO/issues/$map — 티켓 https://github.com/$GH_REPO/issues/$n 을 수행한다." "$(cat "$(rules_file decide)")" "$extra"
    else
      printf '%s\n\n%s\n%s' "https://github.com/$GH_REPO/issues/$n 의 질문을 사용자와 함께 결정한다." "$(cat "$(rules_file decide)")" "$extra"
    fi
  fi
}

# spawn_ticket <num> [extra]  — wayfinder:task → impl, 그 밖 → decide
spawn_ticket() {
  local n="$1" extra="$2" mode=decide
  [ "$(kind_of "$n")" = task ] && mode=impl
  [ -z "$extra" ] && [ -f "$STATE/extra/$n" ] && extra="$(cat "$STATE/extra/$n")"
  spawn "$n" "$(effort_of "$n") #$n" "$(ticket_prompt "$n" "$mode" "$extra")"
}

# in_scope_open <min> — 이번 라운드(번호 ≥ min) 열린 이슈(지도 제외)
in_scope() { # <state> <min>
  gh issue list --repo "$GH_REPO" --state "$1" --limit 300 --json number,labels \
    --jq ".[] | select(.number>=$2 and ([.labels[].name]|index(\"wayfinder:map\")|not)) | .number"
}

# frontier <min> — 열림·미할당·blocker 0·skip 아님
frontier() {
  local min="$1" n
  for n in $(gh issue list --repo "$GH_REPO" --state open --limit 300 --json number,assignees,labels \
      --jq ".[] | select(.number>=$min and (.assignees|length)==0 and ([.labels[].name]|index(\"wayfinder:map\")|not)) | .number"); do
    grep -qx "$n" "$STATE/skip" && continue
    grep -qx "$n" "$STATE/launched" && continue   # 이미 띄웠는데 claim 안 한 세션(로그 반복 방지)
    [ "$(blockers_of "$n")" = 0 ] && echo "$n"
  done
}
