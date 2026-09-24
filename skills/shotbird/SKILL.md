---
name: shotbird
description: 병렬 오케스트라 — 메인 세션이 지휘하고 herdr 탭의 Claude 세션들이 GitHub Issues 티켓을 병렬로 결정·구현한다. frontier 자동 기동, 완료 탭 자동 닫기, 티켓 종결 시 메인 깨우기. 사용자가 /shotbird, "오케스트라로 진행", "병렬 세션으로 뿌려", "herdr 탭으로 전부 띄워"라고 할 때 쓴다. herdr 안(HERDR_ENV=1) + gh CLI + wayfinder 지도/티켓 규약이 전제.
---

# shotbird — 병렬 오케스트라

**너(이 스킬을 읽는 세션)는 메인 세션 = 오케스트라다.** 티켓을 직접 풀지 않는다. 지도와 티켓을 정의하고, 병렬 세션에 뿌리고, 결과를 모아 다음 티켓을 정의한다.
실제 결정·구현은 herdr 탭 1개 = 티켓 1개인 병렬 세션이 하고, 반복 작업은 `scripts/`가 맡는다.

인자(`/shotbird <목표>`)가 있으면 그것이 이번 라운드의 목표다. 없으면 사용자에게 목표(대상 지도·티켓 범위)를 한 문항으로 묻는다.

## 전제 확인 (시작 전 1회)

```bash
test "${HERDR_ENV:-}" = 1 && gh auth status && git rev-parse --show-toplevel
```

- herdr 밖이면 멈추고 알린다. herdr 조작 문법이 필요하면 `herdr` 스킬을 먼저 로드한다.
- 티켓은 현재 리포의 GitHub Issues. 지도 = `wayfinder:map` 라벨 이슈, 티켓 = 그 sub-issue, 종류 라벨 `wayfinder:{research,prototype,grilling,task}`, 소속 `effort:<slug>`(선택). 리포에 이슈 트래커 문서(예: `docs/agents/issue-tracker.md`)가 있으면 그 규약이 우선.
- 이전 라운드 스크립트가 남아 있을 수 있다 — `bash <스킬>/scripts/stop.sh`.

`S`는 이 스킬의 scripts 폴더(이 SKILL.md 옆 `scripts/`)다.

## 역할

| 누가 | 하는 일 | 하지 않는 일 |
|---|---|---|
| **메인(너)** | 지도·티켓 정의(wayfinder 차팅), 병렬 가능 여부 판정, **충돌 티켓을 native blocking으로 직렬화**, 결과를 지도 Decisions에 취합, 병렬 세션이 "메인 세션:"으로 넘긴 일 처리(문서 이관·규칙 반영·교차 티켓 전달), 스크립트 기동 | 티켓 자체를 풀기 |
| **병렬 세션** | claim → 결정(grilling·research) 또는 구현(task) → resolution comment(끝에 `Decisions 요지:`) → close. 후속 티켓은 직접 만들어 sub-issue + blocking | 지도 본문 편집, 결정 세션의 리포 수정·커밋 |
| **스크립트** | frontier 자동 기동 · 완료 탭 닫기 · 종결 시 메인 깨우기 | 판단 |

세션 규칙은 `scripts/rules-decide.txt`·`rules-impl.txt`가 프롬프트에 붙는다. 리포별로 바꾸려면 `<리포>/.orchestra/rules-*.txt` 또는 `<리포>/docs/agents/orchestra/rules-*.txt`를 두면 그것이 우선한다.

## 한 라운드

1. **차팅** — `/wayfinder`로 지도·티켓을 만든다(새 지도보다 기존 지도의 fog 승격이 먼저). 이 라운드 첫 티켓 번호 = `min`.
2. **병렬 판정** — 티켓마다 "다른 세션과 동시에 돌아도 되는가":

   | 충돌 | 처리 |
   |---|---|
   | 같은 파일·같은 테스트 기준값을 고치는 구현 | native `blocked_by`로 직렬화 |
   | 브라우저(프로필 공유) | 한 번에 1개 — 뒤 티켓을 앞 티켓에 blocking(assignee 비움), `.orchestra/extra/<번호>`에 브라우저 허용 추가 지시 |
   | 사용자 자료가 있어야 시작 | `.orchestra/skip`에 번호 |
   | 이미 claim된 티켓 | frontier에서 빠진다 — 다시 돌리려면 assignee를 비우거나 `spawn.sh` |

   blocking API: `gh api --method POST repos/<o>/<r>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker database id>`.
3. **기동** — 셋 다 백그라운드로:

   ```bash
   bash $S/autolaunch.sh <min>   # 2분마다 frontier → 탭 (task=구현, 그 밖=wayfinder 결정)
   bash $S/autoclose.sh          # 티켓 CLOSED + idle 2회 연속 → 탭 닫기
   bash $S/wake.sh <min>         # 미취합 종결 티켓이 생기면 끝나며 메인을 깨움
   ```

   탭 = `<effort> #<번호>`, 에이전트 = `t<번호>`, 첫 입력 `/advisor fable`(`ORCH_FIRST_INPUT`로 변경) → 작업 프롬프트.
   티켓 밖 작업: `bash $S/spawn.sh --raw <번호>r "<effort> #<번호>r" "<프롬프트>"` — 완료 판정은 `#<번호>`를 언급한 커밋.
4. **취합(깨어날 때마다)** — `wake.sh` 출력의 티켓마다:
   - resolution comment의 `Decisions 요지`를 지도 Decisions에 한 줄(링크는 이름으로), 승격된 fog는 Not yet specified에서 지운다. 지도 본문은 **고치기 직전에 새로 받아** 고친다.
   - `메인 세션:` 줄·문서 반영 요청 처리 → 커밋·푸시.
   - 새로 생긴 티켓을 다시 병렬 판정(2) — 충돌이면 blocking. 풀린 것은 autolaunch가 띄운다.
   - 처리한 번호를 `.orchestra/consolidated`에 적고 `wake.sh <min>`을 다시 띄운다.
5. **종료** — 범위 안 열린 티켓이 skip 말고 0이면 autolaunch가, 남은 탭이 없으면 autoclose가 끝난다. `stop.sh`로 마무리하고 사용자에게 산출물(결정·커밋·문서·파생 티켓)을 표로 종합 보고.

## 안전 규칙

- 여러 세션이 **같은 작업 트리**를 쓴다 — `git add`는 자기 파일만, `add -A`·`stash`·`checkout --`·`pull --rebase` 금지, fetch 후 push(거절되면 멈춤).
- 지도 본문은 메인만 고친다(동시 편집은 덮어쓰기).
- autoclose는 이름 `t<키>` + 탭 이름이 `#<키>`로 끝나는 것만 닫는다. blocked(질문창)는 닫지 않는다.
- 도는 세션(working/blocked)에 입력을 보내지 않는다 — 질문창에 보낸 키는 답이 된다.
- **스크립트는 `stop.sh`로만 끈다** — Windows에서는 백그라운드 작업을 멈춰도 bash 자식이 살아남아 탭을 계속 띄운다. 스크립트를 고쳐 다시 띄울 때도 `stop.sh` 먼저.
- Windows 파이썬 출력의 `\r`은 `tr -d '\r'`로 벗긴다(스크립트에 반영됨).

## 상태 파일 (`<리포>/.orchestra/`, gitignore 권장)

`launched`(띄운 키 — 다시 안 띄움) · `skip`(자동 기동 제외) · `consolidated`(취합 끝난 번호) · `extra/<번호>`(티켓별 추가 지시) · `orchestra.log`.
