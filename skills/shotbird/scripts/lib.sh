#!/bin/bash
# orchestra 공통 함수 — ../SKILL.md (/shotbird) 참조.
# 현재 디렉토리의 git 리포 = 대상. 이슈 = 그 리포의 GitHub Issues(gh CLI). herdr 안(HERDR_ENV=1)에서만 기동.
#
# 설정(환경변수, 모두 선택):
#   ORCH_AGENT_KIND   병렬 세션 에이전트 종류 (기본 claude)
#   ORCH_FIRST_INPUT  에이전트 기동 직후 첫 입력 (기본 "/advisor fable", 빈 문자열이면 생략)
#   ORCH_ADVISOR_FALLBACK  Fable advisor를 못 쓸 때 보낼 입력 (기본 "/advisor opus", 빈 문자열이면 폴백 안 함)
#   ORCH_WAYFINDER    결정 티켓에 쓰는 wayfinder 호출 (기본 "/mattpocock-skills:wayfinder")
#   ORCH_MAX_SESSIONS 동시에 떠 있는 병렬 세션(t<키>) 상한 (기본 6 — autolaunch가 넘으면 다음 주기로 미룬다)
#   ORCH_WORKTREE     구현 세션마다 자기 git worktree(<리포>-t<키>, 브랜치 orch/t<키>) — 기본 1, 0이면 옛 방식(같은 작업 트리)
#   ORCH_WORKTREE_LINKS  worktree에 본 폴더를 가리키는 링크로 둘 gitignore 폴더(공백 구분, 기본 "node_modules" — 본 폴더에 있을 때만)
#   ORCH_GH_REPO      owner/name 직접 지정(기본 = gh repo view) — GitHub 원격이 없는 시험 리포에서 merge.sh 자가 시험용
#   병합기(merge.sh) 설정은 merge.sh 머리말 참조.
# 리포별 세션 규칙 덮어쓰기: <리포>/.orchestra/rules-{decide,impl}.txt → <리포>/docs/agents/orchestra/rules-*.txt → 스킬 기본값

# Git Bash(MSYS)는 "/advisor fable"처럼 /로 시작하는 인자를 Windows 경로("C:/Program Files/Git/advisor fable")로 바꿔
# herdr에 넘긴다 — 슬래시 명령이 일반 프롬프트로 들어가던 결함(2026-09-24 발견). 이 스크립트들의 인자 변환을 끈다.
export MSYS_NO_PATHCONV=1

SKILL_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "git 리포 안에서 실행할 것"; exit 1; }
GH_REPO="${ORCH_GH_REPO:-$(cd "$REPO" && gh repo view --json nameWithOwner --jq .nameWithOwner)}" || { echo "gh repo view 실패"; exit 1; }
STATE="$REPO/.orchestra"
mkdir -p "$STATE/extra"
touch "$STATE/launched" "$STATE/skip" "$STATE/consolidated" "$STATE/human-queue.tsv"
LOG="$STATE/orchestra.log"
AGENT_KIND="${ORCH_AGENT_KIND:-claude}"
FIRST_INPUT="${ORCH_FIRST_INPUT-/advisor fable}"
ADVISOR_FALLBACK="${ORCH_ADVISOR_FALLBACK-/advisor opus}"
WAYFINDER="${ORCH_WAYFINDER:-/mattpocock-skills:wayfinder}"
USE_WORKTREE="${ORCH_WORKTREE:-1}"
WORKTREE_LINKS="${ORCH_WORKTREE_LINKS-node_modules}"
touch "$STATE/worktrees"

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

# worktree_path <key> / worktree_branch <key>
worktree_path() { echo "${REPO}-t$1"; }
worktree_branch() { echo "orch/t$1"; }
winpath() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
fwdpath() { cygpath -m "$1" 2>/dev/null || echo "$1"; }   # C:/…/… — Git Bash·PowerShell 어느 쪽에 붙여도 백슬래시가 안 뭉개진다

# worktree_links <wt> — 본 폴더의 gitignore 폴더(ORCH_WORKTREE_LINKS, node_modules 등)를 링크(junction)로 — 설치 시간·디스크 절약
worktree_links() {
  local d
  for d in $WORKTREE_LINKS; do
    [ -d "$REPO/$d" ] && [ ! -e "$1/$d" ] && cmd /c mklink /J "$(winpath "$1/$d")" "$(winpath "$REPO/$d")" > /dev/null 2>&1
  done
}

# worktree_make <key> — origin/main에서 자기 브랜치로 worktree를 만든다(이미 있으면 그대로). 경로를 echo, 실패 시 빈 값.
#   만든 것만 $STATE/worktrees에 적는다 — worktree_drop은 여기 적힌 것만 지운다(사람이 만든 worktree 보호).
worktree_make() {
  local key="$1" wt br d
  wt=$(worktree_path "$key"); br=$(worktree_branch "$key")
  if [ ! -d "$wt" ]; then
    git -C "$REPO" worktree prune
    git -C "$REPO" fetch -q origin || { log "t$key worktree: fetch 실패"; return 1; }
    git -C "$REPO" worktree add -q -b "$br" "$wt" origin/main 2>>"$LOG" \
      || git -C "$REPO" worktree add -q "$wt" "$br" 2>>"$LOG" || { log "t$key worktree add 실패"; return 1; }
    grep -qx "$key" "$STATE/worktrees" || echo "$key" >> "$STATE/worktrees"
    worktree_links "$wt"
    log "t$key worktree $wt ($br)"
  fi
  echo "$wt"
}

# worktree_drop <key> — 오케스트라가 만든 worktree만 지운다. 브랜치는 origin/main에 합쳐졌을 때만 지우고, 아니면 남기고 기록.
worktree_drop() {
  local key="$1" wt br d
  grep -qx "$key" "$STATE/worktrees" || return 0
  wt=$(worktree_path "$key"); br=$(worktree_branch "$key")
  for d in $WORKTREE_LINKS; do   # 링크를 먼저 끊는다 — 링크 대상(본 폴더)을 지우지 않게
    [ -e "$wt/$d" ] && cmd /c rmdir "$(winpath "$wt/$d")" > /dev/null 2>&1
  done
  # Windows: 방금 닫은 탭의 셸·에디터가 폴더 핸들을 잠깐 쥐고 있어 remove가 Permission denied로 빈 껍데기를 남긴다(2026-09-26 2/5).
  # 핸들 해제를 기다려 1회 재시도하고, git 등록은 풀렸는데 폴더만 남으면 지운다.
  if ! git -C "$REPO" worktree remove --force "$wt" 2>>"$LOG"; then
    sleep 10; git -C "$REPO" worktree remove --force "$wt" 2>>"$LOG"
  fi
  git -C "$REPO" worktree prune
  [ -d "$wt" ] && ! git -C "$REPO" worktree list --porcelain | grep -qF "worktree $wt" && rm -rf "$wt" 2>>"$LOG"
  if [ -d "$wt" ]; then log "t$key worktree 폴더 삭제 실패 — $wt 남음(수동 정리)"; else log "t$key worktree removed"; fi
  git -C "$REPO" fetch -q origin
  if branch_merged "$key"; then
    git -C "$REPO" branch -D "$br" > /dev/null 2>&1
  else
    log "t$key 브랜치 $br 는 main에 없음 — 지우지 않고 남김(합치지 않은 커밋 확인 필요)"
  fi
  sed -i "/^$key\$/d" "$STATE/worktrees"
}

# branch_merged <key> — 브랜치 orch/t<key>의 내용이 origin/main에 있는가.
#   병합기(merge.sh)는 커밋을 main 위에 다시 올리므로(cherry-pick) 해시가 바뀐다 — 조상 판정만으로는 "main에 없음"이 된다.
#   ① 조상 ② merge-state에 그 브랜치 끝 커밋이 merged로 기록 ③ git cherry로 같은 패치가 모두 main에 있음 — 하나면 합쳐진 것.
branch_merged() {
  local br tip
  br=$(worktree_branch "$1")
  tip=$(git -C "$REPO" rev-parse -q --verify "$br^{commit}") || return 1
  git -C "$REPO" merge-base --is-ancestor "$tip" origin/main 2>/dev/null && return 0
  awk -v k="$1" -v c="$tip" '$1 == k && $2 == c && $3 == "merged" { f = 1 } END { exit !f }' "$MSTATE" 2>/dev/null && return 0
  ! git -C "$REPO" cherry origin/main "$tip" 2>/dev/null | grep -q '^+'
}

# ── 병합 큐 (merge.sh · enqueue.sh) ──
# merge-queue = 세션이 덧붙이기만 하는 기록: "<키> <커밋 40자> [epoch]" 한 줄. 같은 키는 마지막 줄이 유효(재등록).
# merge-state = 병합기가 덧붙이는 처리 결과: "<키> <커밋> merged <main 커밋> | rejected <사유> | skipped <사유>".
# 대기(pending) = 키별 마지막 줄의 (키, 커밋)이 merge-state에 없는 것. 파일을 고쳐 쓰지 않으므로 세션 쓰기와 경합이 없다.
QUEUE="$STATE/merge-queue"; MSTATE="$STATE/merge-state"
touch "$QUEUE" "$MSTATE"
# queue_clean — BOM(UTF-8·UTF-16)·CR·NUL을 벗긴 큐 본문(PowerShell >>가 UTF-16/BOM으로 써도 읽히게)
queue_clean() { LC_ALL=C sed -e 's/^\xEF\xBB\xBF//' -e 's/^\xFF\xFE//' "$QUEUE" | LC_ALL=C tr -d '\r\000'; }
# queue_pending — 대기 항목 "키 커밋 epoch"를 등록 순서(키의 마지막 줄 기준)로
queue_pending() {
  queue_clean | awk -v st="$MSTATE" '
    BEGIN { while ((getline l < st) > 0) { split(l, f, " "); done[f[1] " " f[2]] = 1 } }
    $0 ~ /^[0-9]+r? [0-9a-f]{40}( [0-9]+)?$/ { last[$1] = $2; ep[$1] = ($3 == "" ? 0 : $3); pos[$1] = NR }
    END { for (k in last) if (!((k " " last[k]) in done)) print pos[k], k, last[k], ep[k] }' | sort -n | cut -d' ' -f2-
}
queue_invalid() { queue_clean | grep -nvE '^([0-9]+r? [0-9a-f]{40}( [0-9]+)?)?$'; }   # 형식이 틀린 줄(줄번호:내용)
queue_has_pending() { queue_pending | awk -v k="$1" '$1 == k { f = 1 } END { exit !f }'; }
# merger_alive — 병합기 락(merge.lock/pid)의 프로세스가 살아 있는가
merger_alive() { local p; p=$(cat "$STATE/merge.lock/pid" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

# spawn <key> <tab-label> <prompt> [cwd]
#   key = 에이전트 이름 접미사(보통 이슈 번호; 닫힌 이슈의 후속 작업은 "<번호>r")
#   새 탭 1개 + 에이전트 t<key> → 첫 입력 → 작업 프롬프트. cwd 기본 = 본 폴더.
spawn() {
  local key="$1" label="$2" prompt="$3" cwd="${4:-$REPO}" tab pane
  grep -qx "$key" "$STATE/launched" && { log "skip $key (이미 띄움)"; return 0; }
  if herdr agent get "t$key" > /dev/null 2>&1; then
    echo "$key" >> "$STATE/launched"; log "skip $key (t$key 이미 실행 중)"; return 0
  fi
  echo "$key" >> "$STATE/launched"
  tab=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$cwd" --label "$label" --no-focus)
  pane=$(echo "$tab" | python -c "import sys,json;print(json.load(sys.stdin)['result']['root_pane']['pane_id'])" | tr -d '\r')
  if ! herdr agent start "t$key" --kind "$AGENT_KIND" --pane "$pane" --timeout 60000 > /dev/null; then
    log "t$key start FAIL"; return 1
  fi
  [ -n "$FIRST_INPUT" ] && set_first_input "t$key"
  if herdr agent prompt "t$key" "$prompt" > /dev/null; then log "t$key launched $pane ($label)"; else log "t$key prompt FAIL"; fi
}

# rules_text <decide|impl> — 규칙 파일의 <리포>·<skip>을 실제 절대 경로로 바꿔 낸다(worktree 안에서는 .orchestra가 없다).
rules_text() {
  local esc='s/[\\&#]/\\&/g' skip repo scripts   # Windows 경로의 \ 가 sed 역참조(\2 등)로 읽히지 않게
  skip=$(winpath "$STATE/skip" | sed "$esc"); repo=$(winpath "$REPO" | sed "$esc")
  scripts=$(fwdpath "$SKILL_SCRIPTS" | sed "$esc")   # 세션이 명령으로 붙여 넣을 경로 — 슬래시형
  sed -e "s#<리포>/\.orchestra/skip#$skip#g" -e "s#<리포>#$repo#g" -e "s#<스크립트>#$scripts#g" "$(rules_file "$1")"
}

# ticket_prompt <num> <decide|impl> [extra] [worktree]
ticket_prompt() {
  local n="$1" mode="$2" extra="$3" wt="$4" map head
  if [ "$mode" = impl ]; then
    head="https://github.com/$GH_REPO/issues/$n 을 구현한다. 결정 출처는 이슈 본문에 링크된 결정 이슈의 resolution comment."
    [ -n "$wt" ] && head="$head
작업 폴더 = 이 세션 전용 git worktree $(winpath "$wt") (브랜치 $(worktree_branch "$n"), origin/main에서 시작). 본 폴더 $(winpath "$REPO")는 고치지 않는다 — 거기의 gitignore 자료(로컬 문서·설정)는 절대 경로로 읽기만."
    [ -z "$wt" ] && head="$head
(worktree 없이 본 폴더에서 다른 세션과 같은 작업 트리를 쓴다 — 규칙 3의 worktree 절차 대신: add는 자기 파일만, 커밋은 \`git commit -- <자기 경로들>\`, stash·checkout -- 금지, rebase·push 없이 \`bash $(fwdpath "$SKILL_SCRIPTS")/enqueue.sh $n --dirty-ok\`로 병합 큐에 등록.)"
    printf '%s\n\n%s\n%s' "$head" "$(rules_text impl)" "$extra"
  else
    map=$(map_of "$n")
    if [ -n "$map" ]; then
      printf '%s\n\n%s\n%s' "$WAYFINDER https://github.com/$GH_REPO/issues/$map — 티켓 https://github.com/$GH_REPO/issues/$n 을 수행한다." "$(rules_text decide)" "$extra"
    else
      printf '%s\n\n%s\n%s' "https://github.com/$GH_REPO/issues/$n 의 질문을 사용자와 함께 결정한다." "$(rules_text decide)" "$extra"
    fi
  fi
}

# spawn_ticket <num> [extra]  — wayfinder:task → impl(자기 worktree), 그 밖 → decide(본 폴더, 파일 수정 없음)
spawn_ticket() {
  local n="$1" extra="$2" mode=decide wt=""
  [ "$(kind_of "$n")" = task ] && mode=impl
  [ -z "$extra" ] && [ -f "$STATE/extra/$n" ] && extra="$(cat "$STATE/extra/$n")"
  if [ "$mode" = impl ] && [ "$USE_WORKTREE" = 1 ]; then
    wt=$(worktree_make "$n") || wt=""
    [ -z "$wt" ] && log "t$n worktree 실패 — 본 폴더에서 기동"
  fi
  spawn "$n" "$(effort_of "$n") #$n" "$(ticket_prompt "$n" "$mode" "$extra" "$wt")" "${wt:-$REPO}"
}

# in_scope_open <min> — 이번 라운드(번호 ≥ min) 열린 이슈(지도 제외)
in_scope() { # <state> <min>
  gh issue list --repo "$GH_REPO" --state "$1" --limit 300 --json number,labels \
    --jq ".[] | select(.number>=$2 and ([.labels[].name]|index(\"wayfinder:map\")|not)) | .number"
}

# held_ids — 자동 기동에서 뺄 번호 = skip(번호 한 줄, 판정 대기) ∪ human-queue.tsv 첫 열(사람 대기열)
#   human-queue.tsv 한 줄 = 번호<TAB>누가<TAB>무엇<TAB>기한(YYYY-MM-DD 또는 -)<TAB>마지막 확인(YYYY-MM-DD)
held_ids() { { cat "$STATE/skip"; cut -f1 "$STATE/human-queue.tsv"; } 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+r?$'; }

# human_digest — 사람 대기열 요약(기한 지남·기한 없음·전체). wake가 하루 1회 출력한다.
human_digest() {
  local today; today=$(date +%F)
  awk -F'\t' -v t="$today" '
    NF>=3 && $1 ~ /^[0-9]/ {
      n++
      if ($4!="" && $4!="-" && $4<t) { o++; print "  기한 지남 #" $1 " [" $2 "] " $3 " (기한 " $4 ", 마지막 확인 " $5 ")" }
      else if ($4=="" || $4=="-") nd++
    }
    END { printf "사람 대기열 %d건 — 기한 지남 %d · 기한 없음 %d\n", n, o, nd }' "$STATE/human-queue.tsv"
}

# frontier <min> — 열림·미할당·blocker 0·skip·사람 대기열 아님
frontier() {
  local min="$1" n held
  held=$(held_ids)
  for n in $(gh issue list --repo "$GH_REPO" --state open --limit 300 --json number,assignees,labels \
      --jq ".[] | select(.number>=$min and (.assignees|length)==0 and ([.labels[].name]|index(\"wayfinder:map\")|not)) | .number"); do
    printf '%s
' "$held" | grep -qx "$n" && continue
    grep -qx "$n" "$STATE/launched" && continue   # 이미 띄웠는데 claim 안 한 세션(로그 반복 방지)
    [ "$(blockers_of "$n")" = 0 ] && echo "$n"
  done
}
