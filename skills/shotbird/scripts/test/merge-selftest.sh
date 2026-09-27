#!/bin/bash
# 사용: bash merge-selftest.sh [작업 폴더]   — 병합기(merge.sh)·enqueue.sh 자가 시험. GitHub·herdr 없이, 임시 bare origin 위에서.
# 실제 리포의 main은 건드리지 않는다. 대조 실행 기록(1건 깨뜨리기·충돌 반려·flaky 재시험·main 이동·금지 경로·이미 main)을 남기고
# 기대와 다르면 FAIL, 모두 맞으면 PASS n/n. 작업 폴더 기본 = mktemp -d(끝나도 지우지 않는다 — 로그 확인용).
set -u
S="$(cd "$(dirname "$0")/.." && pwd)"
W="${1:-$(mktemp -d)}"; mkdir -p "$W"; cd "$W" || exit 1
rm -rf origin.git repo repo-* mover
export ORCH_GH_REPO=local/selftest ORCH_MERGE_NOTIFY=0 ORCH_MERGE_INTERVAL=1 FLAKY_MARK="$W/flaky.mark" MOVE_MARK="$W/move.mark"
unset HERDR_ENV
export GIT_AUTHOR_NAME=selftest GIT_AUTHOR_EMAIL=selftest@example.invalid GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@example.invalid
rm -f "$FLAKY_MARK" "$MOVE_MARK"
q() { "$@" > /dev/null 2>&1; }

# ── 원격(bare) + 본 리포 ──
q git init --bare -b main origin.git
git clone -q origin.git repo 2> /dev/null; cd repo
git config core.autocrlf false; q git checkout -b main
printf '.orchestra/\n' > .gitignore
printf 'base\n' > shared.txt; printf 'base\n' > shared2.txt
# 전체 테스트 = check.sh: BROKEN 글자가 든 파일이 있으면 빨강. flaky.txt가 있으면 첫 1회만 빨강(가짜 실패).
# MOVE_ONCE가 켜져 있으면 첫 시험 중에 다른 클론에서 main에 무관한 커밋을 push(병합기 밖에서 main이 움직임 — 오케스트라 직접 커밋 흉내).
cat > check.sh <<'EOF'
#!/bin/bash
if [ -f flaky.txt ] && [ ! -f "$FLAKY_MARK" ]; then touch "$FLAKY_MARK"; echo "flaky fail"; exit 1; fi
if [ -f move.txt ] && [ ! -f "$MOVE_MARK" ]; then
  touch "$MOVE_MARK"
  ( cd "$(dirname "$FLAKY_MARK")/mover" && git pull -q && echo moved > outside.txt && git add outside.txt && git commit -qm "outside: main moved" && git push -q origin HEAD:main )
fi
if grep -l BROKEN -- *.txt 2> /dev/null; then echo "broken"; exit 1; fi
echo ok
EOF
git add -A; q git commit -m base; q git push -q origin HEAD:main; q git fetch origin
mkdir -p .orchestra
export ORCH_MERGE_TEST="bash check.sh"
cd "$W"; git clone -q -c core.autocrlf=false origin.git mover 2> /dev/null; cd "$W/repo"

# mk <키> <파일> <내용> [base 커밋]  — 세션 worktree 흉내: orch/t<키>에서 커밋 후 enqueue.sh
mk() {
  local k=$1 f=$2 c=$3 base=${4:-origin/main}
  q git fetch origin; q git worktree add -b "orch/t$k" "$W/repo-t$k" "$base"
  ( cd "$W/repo-t$k" && mkdir -p "$(dirname "$f")" && printf '%s\n' "$c" > "$f" && git add -A && q git commit -m "t$k: $f (#$k)" && bash "$S/enqueue.sh" "$k" > /dev/null ) || echo "mk $k 실패"
}
BASE0=$(git rev-parse origin/main)
pass=0; total=0
ok() { total=$((total + 1)); if eval "$2"; then pass=$((pass + 1)); echo "PASS $1"; else echo "FAIL $1"; fi; }
st() { awk -v k="$1" '$1 == k { s = $3 } END { print s }' .orchestra/merge-state; }
onmain() { git -C "$W/repo" fetch -q origin; git -C "$W/repo" show origin/main:"$1" > /dev/null 2>&1; }

echo "── 1) 묶음 4건 중 1건 깨뜨리기(bisect) ──"
mk 101 f101.txt good; mk 102 f102.txt BROKEN; mk 103 f103.txt good; mk 104 f104.txt good
bash "$S/merge.sh" --once
ok "101·103·104 병합" '[ "$(st 101)$(st 103)$(st 104)" = mergedmergedmerged ] && onmain f101.txt && onmain f103.txt && onmain f104.txt'
ok "102만 반려(test)" '[ "$(st 102)" = rejected ] && grep -q "^102 .* rejected test" .orchestra/merge-state && ! onmain f102.txt'
ok "branch_merged: 101 합쳐짐 · 102 아님" '( . "$S/lib.sh"; branch_merged 101 && ! branch_merged 102 )'

echo "── 2) 충돌 반려: origin/main과 충돌 + 묶음 안 충돌은 미룸 ──"
mk 105 shared.txt X105
bash "$S/merge.sh" --once
mk 106 shared.txt Y106 "$BASE0"                      # 옛 main에서 같은 줄을 고침 → 현재 main과 충돌
mk 107 shared2.txt X107; mk 108 shared2.txt Y108     # 같은 묶음에서 서로 충돌 → 107 병합, 108 미룸 → 다음 묶음에서 main과 충돌 반려
bash "$S/merge.sh" --once
ok "106 반려(conflict, main과)" 'grep -q "^106 .* rejected conflict" .orchestra/merge-state'
ok "107 병합 · 108 미룸 뒤 반려" '[ "$(st 107)" = merged ] && grep -q "merge defer t108" .orchestra/orchestra.log && grep -q "^108 .* rejected conflict" .orchestra/merge-state'

echo "── 3) 가짜 실패 1회(flaky) → 재시험 green이면 병합 ──"
mk 109 flaky.txt f
bash "$S/merge.sh" --once
ok "109 flaky 재시험 뒤 병합" '[ "$(st 109)" = merged ] && grep -q "merge flaky: 109" .orchestra/orchestra.log'

echo "── 4) 시험 중 main이 병합기 밖에서 움직임(겹치는 파일 없음) → 재시험 없이 새 main 위에 push ──"
mk 110 move.txt m
bash "$S/merge.sh" --once
ok "110 병합 + outside 커밋 보존(fast-forward)" '[ "$(st 110)" = merged ] && onmain move.txt && onmain outside.txt && grep -q "merge push rejected" .orchestra/orchestra.log'

echo "── 5) 금지 경로(ORCH_MERGE_FORBID) ──"
mk 111 release/app.html x
ORCH_MERGE_FORBID='^release/' bash "$S/merge.sh" --once
ok "111 반려(forbidden)" 'grep -q "^111 .* rejected forbidden" .orchestra/merge-state && ! onmain release/app.html'

echo "── 6) 재등록(반려 뒤 고쳐서 같은 키) · BOM/CRLF 줄 · 형식 틀린 줄 ──"
( cd "$W/repo-t102" && printf 'fixed\n' > f102.txt && git add -A && q git commit -m "t102: fix (#102)" && q git fetch origin && q git rebase origin/main && git rev-parse HEAD > "$W/t102.sha" )
printf '\xEF\xBB\xBF102 %s\r\n' "$(cat "$W/t102.sha")" >> .orchestra/merge-queue   # PowerShell식 BOM·CRLF
printf 'garbage line\n' >> .orchestra/merge-queue
bash "$S/merge.sh" --once
ok "102 재등록 병합(BOM·CRLF 줄 읽힘)" '[ "$(st 102)" = merged ] && onmain f102.txt && grep -q "큐 형식이 틀린 줄 무시" .orchestra/orchestra.log'

echo "── 7) 이미 main에 있는 커밋 → skipped, 대기 0 ──"
printf '112 %s\n' "$(git rev-parse origin/main)" >> .orchestra/merge-queue
bash "$S/merge.sh" --once
ok "112 skipped · 대기 없음" '[ "$(st 112)" = skipped ] && [ -z "$( . "$S/lib.sh"; queue_pending )" ]'
ok "main 이력 선형(merge 커밋 없음)" '[ -z "$(git rev-list --merges origin/main)" ]'
ok "락 해제" '[ ! -d .orchestra/merge.lock ]'

echo "── 8) 락 경합 · enqueue 예외 ──"
mkdir .orchestra/merge.lock; echo $$ > .orchestra/merge.lock/pid          # 살아 있는 pid(이 셸)가 쥔 락
ok "락이 살아 있으면 두 번째 병합기는 곧바로 끝남" '! bash "$S/merge.sh" --once > /dev/null 2>&1 && [ "$(cat .orchestra/merge.lock/pid)" = $$ ]'
echo 999999 > .orchestra/merge.lock/pid                                   # 죽은 pid → 회수
ok "죽은 락은 회수" 'bash "$S/merge.sh" --once > /dev/null 2>&1 && [ ! -d .orchestra/merge.lock ] && grep -q "죽은 락 회수" .orchestra/orchestra.log'
q git fetch origin; q git worktree add -b orch/t113 "$W/repo-t113" origin/main
ok "커밋 없는 등록은 종료 2(직접 close)" '( cd "$W/repo-t113" && bash "$S/enqueue.sh" 113 > /dev/null; [ $? = 2 ] )'
ok "커밋 안 한 변경이 있으면 거절" '( cd "$W/repo-t113" && echo x >> shared.txt && ! bash "$S/enqueue.sh" 113 > /dev/null; r=$?; git checkout -q -- shared.txt; exit $r )'

echo "── 기록 ──"
grep -E " merge[ :]" .orchestra/orchestra.log | sed 's/^/  /'
echo "── 통계 ──"; bash "$S/merge.sh" --stats | sed 's/^/  /'
echo "PASS $pass/$total  (작업 폴더 $W)"
[ "$pass" = "$total" ]
