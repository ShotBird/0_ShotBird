#!/bin/bash
# orchestra 공통 함수 — ../SKILL.md (/shotbird) 참조.
# 현재 디렉토리의 git 리포 = 대상. 이슈 = 그 리포의 GitHub Issues(gh CLI). herdr 안(HERDR_ENV=1)에서만 기동.
#
# 설정(환경변수, 모두 선택):
#   ORCH_AGENT_KIND   병렬 세션 에이전트 종류 (기본 claude)
#   ORCH_FIRST_INPUT  에이전트 기동 직후 첫 입력 (기본 "/advisor fable", 빈 문자열이면 생략)
#   ORCH_WAYFINDER    결정 티켓에 쓰는 wayfinder 호출 (기본 "/mattpocock-skills:wayfinder")
# 리포별 세션 규칙 덮어쓰기: <리포>/.orchestra/rules-{decide,impl}.txt → <리포>/docs/agents/orchestra/rules-*.txt → 스킬 기본값

SKILL_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "git 리포 안에서 실행할 것"; exit 1; }
GH_REPO="$(cd "$REPO" && gh repo view --json nameWithOwner --jq .nameWithOwner)" || { echo "gh repo view 실패"; exit 1; }
STATE="$REPO/.orchestra"
mkdir -p "$STATE/extra"
touch "$STATE/launched" "$STATE/skip" "$STATE/consolidated"
LOG="$STATE/orchestra.log"
AGENT_KIND="${ORCH_AGENT_KIND:-claude}"
FIRST_INPUT="${ORCH_FIRST_INPUT-/advisor fable}"
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
  [ -n "$FIRST_INPUT" ] && herdr agent prompt "t$key" "$FIRST_INPUT" --wait --timeout 30000 > /dev/null
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
