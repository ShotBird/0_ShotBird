#!/bin/bash
# 사용: merge.sh                 — 병합기(메인 세션이 autolaunch·autoclose처럼 백그라운드로 띄운다)
#       merge.sh --once          — 대기가 빌 때까지(진전이 없으면 거기서) 처리하고 끝(자가 시험·수동 실행)
#       merge.sh --stats [since] — orchestra.log의 병합기 기록으로 통계. since = "MM-DD HH:MM" (그 뒤 기록만)
#
# main에 push하는 것은 이 병합기 하나다(세션은 enqueue.sh로 큐에 등록까지). 예외: 오케스트라(메인) 자신의 통합 빌드·문서 커밋.
# 한 묶음: 큐(.orchestra/merge-queue)에서 최대 N개 → 병합기 전용 worktree(<리포>-merge)에서 origin/main 위에 차례로
#   cherry-pick → 전체 테스트 1회 → green이면 시험한 바로 그 커밋을 main에 push(fast-forward만, force 금지)
#   → 이슈에 병합 커밋 코멘트 + close("닫힘 = main에 있음").
#   빨강이면 반으로 나눠 재시험(bisect) — 범인만 반려하고 나머지는 병합. 1건짜리 빨강은 한 번 더 시험한다(벽시계 테스트 같은
#   가짜 실패 여지 — ORCH_MERGE_RETRY; 재시험이 green이면 병합하고 "flaky"로 기록).
#   cherry-pick 충돌: origin/main 단독 위에서도 충돌하면 반려("rebase 후 재등록"), 묶음 앞 항목과만 충돌하면 다음 묶음으로 미룬다.
#   push가 non-ff로 거절되면(main이 병합기 밖에서 움직임) fetch 후 같은 묶음을 새 main 위에 다시 올린다 — 새 main 커밋과 묶음이
#   고친 파일이 겹치지 않으면 재시험 없이 push, 겹치거나 재적용이 충돌하면 묶음을 대기로 되돌려 다음 주기에 다시 시험한다.
# 반려 알림: 이슈 코멘트 + 세션(t<키>)이 idle/done이면 herdr 메시지(working·blocked면 보류했다가 다음 주기에 — .orchestra/merge-notify).
# 한 번에 하나만 돈다(.orchestra/merge.lock). 결과 .orchestra/merge-state(lib.sh 큐 절), 테스트 로그 .orchestra/merge-logs/(최근 40개).
#
# 설정(환경변수):
#   ORCH_MERGE_TEST     전체 테스트 명령(필수 — 없으면 .orchestra/merge-test 첫 줄). 병합기 worktree에서 bash -c로, 종료 0 = green
#   ORCH_MERGE_BATCH    한 묶음 최대 항목 수 (기본 4)
#   ORCH_MERGE_RETRY    1건짜리 빨강의 재시험 횟수 (기본 1, 0이면 바로 반려)
#   ORCH_MERGE_TIMEOUT  테스트 1회 제한 초 (기본 1800)
#   ORCH_MERGE_FORBID   병합 금지 경로(확장 정규식, 기본 없음) — 세션이 커밋하면 안 되는 배포 산출물 등. 걸리면 반려
#   ORCH_MERGE_INTERVAL 큐 확인 주기 초 (기본 60)
#   ORCH_MERGE_PUSH_RETRY  non-ff 거절 시 재적용·push 재시도 상한 (기본 3)
#   ORCH_MERGE_NOTIFY   0이면 gh·herdr 알림을 하지 않는다(자가 시험) — 기본 1
#   ORCH_MERGE_WORKTREE 병합기 worktree 경로 (기본 <리포>-merge) — .orchestra/worktrees에 적지 않는다(autoclose가 지우지 않게)
. "$(dirname "$0")/lib.sh"
MODE="${1:-loop}"

if [ "$MODE" = --stats ]; then
  awk -v since="${2:-}" '
    since != "" && substr($0, 1, length(since)) < since { next }
    / merge test set=/            { tests++; if ($0 ~ /→ red/) red++ }
    / merge flaky: /              { flaky++ }
    / merge pushed /              { pushes++ }
    / merge push rejected /       { nonff++ }
    / merge batch done: /         { batches++; for (i = 1; i <= NF; i++) { split($i, kv, "="); if (kv[1] in s) s[kv[1]] += kv[2] } }
    BEGIN { s["merged"]; s["commits"]; s["rejected"]; s["deferred"] }
    END {
      printf "묶음 %d · push %d · non-ff 거절 %d(병합기 재적용)\n", batches, pushes, nonff
      printf "병합 항목 %d(커밋 %d) · 반려 %d · 미룸 %d\n", s["merged"], s["commits"], s["rejected"], s["deferred"]
      printf "전체 테스트 %d회(빨강 %d, flaky 재시험 green %d)\n", tests, red, flaky
      if (s["merged"] > 0) printf "항목당 테스트 %.2f · 커밋당 테스트 %.2f\n", tests / s["merged"], (s["commits"] > 0 ? tests / s["commits"] : 0)
    }' "$LOG"
  exit 0
fi

TEST_CMD="${ORCH_MERGE_TEST:-$(head -1 "$STATE/merge-test" 2>/dev/null | tr -d '\r')}"
[ -n "$TEST_CMD" ] || { echo "ORCH_MERGE_TEST(또는 $STATE/merge-test 첫 줄)로 전체 테스트 명령을 정할 것"; exit 1; }
BATCH=${ORCH_MERGE_BATCH:-4}; RETRY=${ORCH_MERGE_RETRY:-1}; TIMEOUT=${ORCH_MERGE_TIMEOUT:-1800}
FORBID="${ORCH_MERGE_FORBID:-}"; INTERVAL=${ORCH_MERGE_INTERVAL:-60}; PUSH_RETRY=${ORCH_MERGE_PUSH_RETRY:-3}
NOTIFY=${ORCH_MERGE_NOTIFY:-1}; MW="${ORCH_MERGE_WORKTREE:-${REPO}-merge}"
LOGDIR="$STATE/merge-logs"; mkdir -p "$LOGDIR"; touch "$STATE/merge-notify"

# ── 락: 한 번에 하나 ──
if ! mkdir "$STATE/merge.lock" 2>/dev/null; then
  merger_alive && { echo "병합기가 이미 돈다 (pid $(cat "$STATE/merge.lock/pid"))"; exit 1; }
  log "merge: 죽은 락 회수 (pid $(cat "$STATE/merge.lock/pid" 2>/dev/null))"
fi
echo $$ > "$STATE/merge.lock/pid"
trap 'rm -rf "$STATE/merge.lock"' EXIT
trap 'exit 143' TERM INT

# ── 병합기 전용 worktree(detached) ──
mw() { git -C "$MW" "$@"; }
if [ ! -d "$MW" ]; then
  git -C "$REPO" worktree prune
  git -C "$REPO" fetch -q origin
  git -C "$REPO" worktree add -q --detach "$MW" origin/main 2>>"$LOG" || { log "merge: worktree 생성 실패 $MW"; exit 1; }
  log "merge: worktree $MW"
fi
worktree_links "$MW"

keys_of() { local i o=""; for i in "$@"; do o="$o,${i%%:*}"; done; echo "${o#,}"; }
# reset_to <커밋> — 진행 중인 cherry-pick을 버리고 그 커밋으로. clean은 -x 없이(링크한 node_modules 등 ignore 폴더는 둔다)
reset_to() { mw cherry-pick --quit > /dev/null 2>&1; mw reset -q --hard "$1" && mw clean -fdq; }

# apply_item <키:커밋> — 현재 HEAD 위에 그 항목의 커밋(BASE..커밋, merge 커밋 제외)을 차례로 cherry-pick.
#   0 성공 · 1 충돌(HEAD 원복, CONFLICT_FILES). 이미 main에 같은 변경이라 비는 커밋은 건너뛴다.
apply_item() {
  local sha=${1#*:} before c
  before=$(mw rev-parse HEAD)
  for c in $(mw rev-list --reverse --no-merges "$BASE..$sha"); do
    mw cherry-pick "$c" > /dev/null 2>&1 && continue
    if [ -z "$(mw ls-files -u)" ] && mw diff --cached --quiet; then
      mw cherry-pick --skip > /dev/null 2>&1 && continue
    fi
    CONFLICT_FILES=$(mw diff --name-only --diff-filter=U | tr '\n' ' ')
    mw cherry-pick --abort > /dev/null 2>&1; reset_to "$before"; return 1
  done
}
build_set() { local i; reset_to "$BASE"; for i in "$@"; do apply_item "$i" || return 1; done; }

run_test() { # <항목들(기록용)> — 병합기 worktree의 현재 상태로 전체 테스트 1회
  local f t0 rc
  TESTS=$((TESTS + 1)); f="$LOGDIR/$(date +%m%d-%H%M%S)-$TESTS.log"; t0=$(date +%s)
  ( cd "$MW" && timeout "$TIMEOUT" bash -c "$TEST_CMD" ) > "$f" 2>&1; rc=$?
  LAST_TEST_LOG="$f"
  log "merge test set=[$(keys_of "$@")] → $([ $rc = 0 ] && echo green || echo "red rc=$rc") ($(( $(date +%s) - t0 ))s) log=$(basename "$f")"
  ls -1t "$LOGDIR" | tail -n +41 | while read -r old; do rm -f "$LOGDIR/$old"; done
  return $rc
}
# try_set <항목들> — GOOD + 항목들을 BASE 위에 올려 시험. 0 green(GREEN_SHA = 시험한 커밋) · 1 빨강 · 2 적용 충돌
try_set() {
  build_set "${GOOD[@]}" "$@" || { log "merge apply-conflict set=[$(keys_of "${GOOD[@]}" "$@")] — 시험 안 함"; return 2; }
  run_test "${GOOD[@]}" "$@" || return 1
  GREEN_SHA=$(mw rev-parse HEAD)
}
# resolve <항목들> — 통과하면 GOOD에 더한다. 빨강이면 반으로 나눠 각각(bisect). GOOD은 늘 "함께 시험해 green"인 집합이다.
resolve() {
  local n=$# r h k
  try_set "$@"; r=$?
  [ $r = 0 ] && { GOOD+=("$@"); return; }
  if [ "$n" -gt 1 ]; then h=$((n / 2)); resolve "${@:1:h}"; resolve "${@:h+1}"; return; fi
  if [ $r = 1 ]; then
    for ((k = 0; k < RETRY; k++)); do
      if try_set "$1"; then GOOD+=("$1"); log "merge flaky: $(keys_of "$1") 재시험 green — 가짜 실패로 보고 병합"; return; fi
    done
    reject "$1" test "전체 테스트 빨강(묶음을 나눠 시험해 이 항목에서 깨짐$([ "$RETRY" -gt 0 ] && echo ", 재시험 ${RETRY}회도 빨강"))" "$LAST_TEST_LOG"
  else
    reject "$1" conflict "같은 묶음에서 먼저 병합되는 항목과 cherry-pick 충돌: $CONFLICT_FILES" ""
  fi
}

# ── 알림 ──
live_agents() { herdr agent list 2>/dev/null | python -c "
import sys,json,re
for a in json.load(sys.stdin)['result']['agents']:
    n=a.get('name') or ''
    if re.fullmatch(r't\d+r?',n): print(n,a.get('agent_status'))" | tr -d '\r'; }
gh_comment() { [ "$NOTIFY" = 1 ] && gh issue comment "${1%r}" --repo "$GH_REPO" --body "$2" > /dev/null 2>>"$LOG"; }
# flush_notify — 보류 중인 세션 메시지를 idle/done인 세션에 보낸다. 세션이 없으면 버린다(이슈 코멘트가 남아 있다).
flush_notify() {
  [ "$NOTIFY" = 1 ] && [ "${HERDR_ENV:-}" = 1 ] && [ -s "$STATE/merge-notify" ] || return 0
  local agents key msg st keep=""
  agents=$(live_agents)
  while IFS=$'\t' read -r key msg; do
    [ -z "$key" ] && continue
    st=$(printf '%s\n' "$agents" | awk -v a="t$key" '$1 == a { print $2 }')
    if [ -z "$st" ]; then log "merge notify t$key: 세션 없음 — 이슈 코멘트만"
    elif [ "$st" = idle ] || [ "$st" = done ]; then
      herdr agent prompt "t$key" "$msg" > /dev/null && log "merge notify t$key 보냄" || keep="$keep$key	$msg
"
    else keep="$keep$key	$msg
"; fi
  done < "$STATE/merge-notify"
  printf '%s' "$keep" > "$STATE/merge-notify"
}
reject() { # <키:커밋> <종류 conflict|test|forbidden|missing> <사유> [테스트 로그]
  local key=${1%%:*} sha=${1#*:} tail=""
  echo "$key $sha rejected $2" >> "$MSTATE"; REJ=$((REJ + 1)); PROGRESS=1
  log "merge reject t$key ${sha:0:9} ($2) $3"
  [ "$NOTIFY" = 1 ] || return 0
  [ -n "$4" ] && tail=$(printf '\n<details><summary>테스트 로그 끝 40줄</summary>\n\n```\n%s\n```\n</details>' "$(tail -40 "$4" | tr -d '\r')")
  gh_comment "$key" "병합기: 반려 — \`${sha:0:9}\` ($2) $3.
자기 worktree에서 \`git fetch origin && git rebase origin/main\` → 고친 뒤 전체 테스트 green → \`bash $(fwdpath "$SKILL_SCRIPTS")/enqueue.sh $key\`로 재등록.$tail"
  printf '%s\t%s\n' "$key" "[병합기] #$key 반려($2) — $3. 이슈 코멘트에 자세히. 자기 worktree에서 git fetch origin && git rebase origin/main → 고친 뒤 전체 테스트 green → bash $(fwdpath "$SKILL_SCRIPTS")/enqueue.sh $key 로 재등록. close는 하지 않는다(병합기가 병합 뒤 닫는다)." >> "$STATE/merge-notify"
}
merged() { # <키:커밋> <main 커밋> <묶음 크기>
  local key=${1%%:*} sha=${1#*:}
  echo "$key $sha merged $2" >> "$MSTATE"; PROGRESS=1
  [ "$NOTIFY" = 1 ] || return 0
  gh_comment "$key" "병합기: main \`${2:0:9}\`에 병합 — 브랜치 커밋 \`${sha:0:9}\`, 묶음 $3건, 이 묶음 전체 테스트 ${TESTS}회."
  [ "$key" = "${key%r}" ] && [ "$(state_of "$key")" = OPEN ] && gh issue close "$key" --repo "$GH_REPO" > /dev/null 2>>"$LOG" && log "merge closed #$key"
}

# push_good — 시험한 GREEN_SHA를 main에 fast-forward push. 거절되면 새 main 위에 다시 올려(겹침 없을 때만) 재시도.
push_good() {
  local try=0 nb overlap i commits
  while :; do
    commits=$(git -C "$REPO" rev-list --count "$BASE..$GREEN_SHA")
    if mw push -q origin "$GREEN_SHA:refs/heads/main" 2>>"$LOG"; then
      git -C "$REPO" fetch -q origin
      log "merge pushed ${GREEN_SHA:0:9} keys=$(keys_of "${GOOD[@]}") commits=$commits"
      PUSHED_COMMITS=$commits
      for i in "${GOOD[@]}"; do merged "$i" "$GREEN_SHA" "${#GOOD[@]}"; done
      return 0
    fi
    try=$((try + 1))
    git -C "$REPO" fetch -q origin; nb=$(git -C "$REPO" rev-parse origin/main)
    log "merge push rejected — main이 병합기 밖에서 움직임 ${BASE:0:9}..${nb:0:9} (재시도 $try/$PUSH_RETRY)"
    [ "$try" -gt "$PUSH_RETRY" ] && { log "merge: push 재시도 상한 — 묶음을 대기로 되돌림"; GOOD=(); return 1; }
    overlap=$(comm -12 <(git -C "$REPO" diff --name-only "$BASE" "$nb" | sort -u) <(git -C "$REPO" diff --name-only "$BASE" "$GREEN_SHA" | sort -u) | tr '\n' ' ')
    [ -n "$overlap" ] && { log "merge: 새 main 커밋과 겹치는 파일($overlap) — 묶음을 대기로 되돌려 다음 주기에 재시험"; GOOD=(); return 1; }
    BASE=$nb
    build_set "${GOOD[@]}" || { log "merge: 새 main 위 재적용 충돌 — 묶음을 대기로"; GOOD=(); return 1; }
    GREEN_SHA=$(mw rev-parse HEAD)
    log "merge: 새 main ${nb:0:9} 위에 재적용(겹치는 파일 없음 — 재시험 없이 push)"
  done
}

process_batch() {
  local key sha ep cands=() ok=() i cf files
  TESTS=0; REJ=0; DEF=0; PROGRESS=0; PUSHED_COMMITS=0; GOOD=(); GREEN_SHA=""
  BASE=$(git -C "$REPO" rev-parse origin/main)
  while read -r key sha ep; do
    [ -z "$key" ] && continue
    [ ${#cands[@]} -ge "$BATCH" ] && break
    if ! git -C "$REPO" cat-file -e "$sha^{commit}" 2>/dev/null; then
      git -C "$REPO" fetch -q origin "refs/heads/orch/t$key" 2>/dev/null
      git -C "$REPO" cat-file -e "$sha^{commit}" 2>/dev/null || { reject "$key:$sha" missing "커밋을 찾을 수 없다(로컬·origin/orch/t$key 모두)" ""; continue; }
    fi
    if [ "$(git -C "$REPO" rev-list --count --no-merges "$BASE..$sha")" = 0 ]; then
      echo "$key $sha skipped already-in-main" >> "$MSTATE"; PROGRESS=1; log "merge skip t$key ${sha:0:9} — 이미 main에 있음"
      [ "$NOTIFY" = 1 ] && [ "$key" = "${key%r}" ] && [ "$(state_of "$key")" = OPEN ] && gh_comment "$key" "병합기: \`${sha:0:9}\`는 이미 main에 있다 — 닫는다." && gh issue close "$key" --repo "$GH_REPO" > /dev/null 2>>"$LOG"
      continue
    fi
    if [ -n "$FORBID" ]; then
      files=$(git -C "$REPO" log --format= --name-only --no-merges "$BASE..$sha" | grep -E "$FORBID" | sort -u | tr '\n' ' ')
      [ -n "$files" ] && { reject "$key:$sha" forbidden "병합 금지 경로를 커밋함: $files(되돌린 커밋을 더해 재등록)" ""; continue; }
    fi
    cands+=("$key:$sha")
  done <<< "$(queue_pending)"
  [ ${#cands[@]} = 0 ] && return 0
  log "merge batch start base=${BASE:0:9} keys=$(keys_of "${cands[@]}")"
  # 적용 검사: 차례로 쌓는다. 막히면 main 단독 위에서 다시 — 단독도 막히면 반려, 단독은 되면 다음 묶음으로 미룬다.
  reset_to "$BASE"
  local here
  for i in "${cands[@]}"; do
    if apply_item "$i"; then ok+=("$i"); continue; fi
    cf=$CONFLICT_FILES; here=$(mw rev-parse HEAD); reset_to "$BASE"
    if apply_item "$i"; then DEF=$((DEF + 1)); log "merge defer t${i%%:*} — 묶음 앞 항목과 충돌($cf), 다음 묶음으로"
    else reject "$i" conflict "origin/main 위에서 cherry-pick 충돌: $cf" ""; fi
    reset_to "$here"
  done
  if [ ${#ok[@]} -gt 0 ]; then
    resolve "${ok[@]}"
    [ ${#GOOD[@]} -gt 0 ] && push_good
  fi
  log "merge batch done: merged=${#GOOD[@]} commits=$PUSHED_COMMITS rejected=$REJ deferred=$DEF tests=$TESTS"
}

[ "$MODE" = --once ] || log "merge start batch=$BATCH retry=$RETRY test=\"$TEST_CMD\" worktree=$MW"
last_invalid=""
while :; do
  flush_notify
  inv=$(queue_invalid)
  [ -n "$inv" ] && [ "$inv" != "$last_invalid" ] && log "merge: 큐 형식이 틀린 줄 무시 — $(echo "$inv" | tr '\n' ' ')"
  last_invalid=$inv
  if [ -n "$(queue_pending)" ]; then
    if git -C "$REPO" fetch -q origin; then
      process_batch
      [ "$PROGRESS" = 1 ] && continue   # 진전이 있으면 곧바로 다음 묶음
    else log "merge: fetch 실패 — 다음 주기"; fi
  fi
  [ "$MODE" = --once ] && { flush_notify; exit 0; }
  if [ -z "$(queue_pending)" ] && grep "autolaunch " "$LOG" | tail -1 | grep -q "autolaunch done" \
     && { [ "${HERDR_ENV:-}" != 1 ] || [ -z "$(live_agents)" ]; }; then
    log "merge done"; exit 0
  fi
  sleep "$INTERVAL"
done
