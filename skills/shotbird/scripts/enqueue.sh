#!/bin/bash
# 사용: enqueue.sh <번호> [--dirty-ok]   — 구현 세션이 자기 worktree에서, 전체 테스트 green을 확인한 뒤 실행한다.
# ① 자기 브랜치 orch/t<번호>를 origin에 올린다(--force-with-lease — 자기 브랜치만, main은 절대 아님; 실패해도 등록은 한다 —
#    worktree는 본 리포와 객체 저장소를 같이 써서 병합기가 커밋을 로컬에서 읽는다)
# ② 병합 큐(<리포>/.orchestra/merge-queue)에 "<번호> <HEAD 커밋> <epoch>" 한 줄. 병합기(merge.sh)가 main에 합친 뒤 이슈를 닫는다.
# 재등록(반려 뒤 고쳐서 다시)도 같은 명령 — 같은 번호는 마지막 줄이 유효하다.
# 종료 코드: 0 등록 · 2 병합할 커밋 없음(origin/main에 이미 있음 → 세션이 직접 close) · 1 오류
# --dirty-ok: 커밋하지 않은 변경이 있어도 등록(worktree 없이 본 폴더를 여러 세션이 같이 쓰는 옛 방식 전용).
# lib.sh를 읽지 않는다 — worktree 안에서 gh·herdr 없이 돌아야 한다.
key="${1:?번호}"; dirty_ok="${2:-}"
[[ "$key" =~ ^[0-9]+r?$ ]] || { echo "번호 형식이 아니다: $key (예: 633, 633r)"; exit 1; }
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "git 리포 안에서 실행할 것"; exit 1; }
REPO=$(dirname "$common")   # worktree여도 본 리포(.orchestra가 있는 곳)
STATE="$REPO/.orchestra"
[ -d "$STATE" ] || { echo "$STATE 없음 — 오케스트라 리포가 아니다"; exit 1; }
if [ "$dirty_ok" != --dirty-ok ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "커밋하지 않은 변경이 있다 — 커밋하거나(빌드 산출물이면) 되돌린 뒤 다시 등록:"; git status --short --untracked-files=no; exit 1
fi
git fetch -q origin || { echo "git fetch 실패"; exit 1; }
sha=$(git rev-parse HEAD)
n=$(git rev-list --count --no-merges origin/main..HEAD)
[ "$n" = 0 ] && { echo "병합할 커밋 없음(HEAD의 변경이 이미 origin/main에 있다) — 큐에 넣지 않는다. 세션이 직접 close."; exit 2; }
git push -q --force-with-lease origin "HEAD:refs/heads/orch/t$key" 2>&1 \
  || echo "경고: 브랜치 orch/t$key push 실패 — 등록은 계속한다(병합기는 로컬 객체를 쓴다)"
printf '%s %s %s\n' "$key" "$sha" "$(date +%s)" >> "$STATE/merge-queue"
echo "$(date '+%m-%d %T') enqueue t$key $sha ($n commits)" >> "$STATE/orchestra.log"
echo "등록: #$key ${sha:0:9} (커밋 $n개). 병합기가 main에 합친 뒤 이슈를 닫는다 — 세션은 close하지 말고 끝낸다."
echo "반려되면 이 세션에 [병합기] 메시지와 이슈 코멘트가 온다 → 고쳐서 같은 명령으로 재등록."
