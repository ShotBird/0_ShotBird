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
- **리포의 오케스트라 운영 절을 먼저 읽는다**(wayfinder가 트래커 문서의 "Wayfinding operations"를 읽듯): 리포 이슈 트래커 문서(예: `docs/agents/issue-tracker.md`)의 **"Orchestra operations"** 절 — 그 리포에서만 다른 것(세션 규칙 파일·빌드 산출물 커밋 주체·브라우저·effort 배정). 절차는 이 스킬이 정본이고, 리포에는 스크립트 사본을 두지 않는다.
- **이어받기**(clear·새 대화에서 `/shotbird 이어서`) — 메모 없이 상태를 직접 읽는다:
  라운드 min = `.orchestra/orchestra.log`의 마지막 `autolaunch start min=` · 도는 스크립트 = `ps -ef | grep shotbird/scripts` ·
  진행 중 = 열림+assignee 있는 이슈 · verify 큐 = `gh issue list --state closed --label verify:browser` ·
  미취합 = 번호 ≥ min인 닫힌 이슈 중 `.orchestra/consolidated`에 없는 것. 스크립트·탭 세션은 clear와 무관하게 계속 돌고, wake 알림은 새 대화로 온다.
- **도는 스크립트를 먼저 확인한다** — `ps -ef | grep shotbird/scripts`. **돌고 있으면 끄지 않는다**(탭 세션을 받아 주는 중이다). `stop.sh`는 사용자가 오케스트라를 끝내라고 할 때나 스크립트를 고쳐 다시 띄울 때만.
- **이어받기 + 새 할 일을 한 번에**: `/shotbird 이어서 — <새 목표>`. ① 위 이어받기로 상태를 읽고 미취합 티켓부터 취합 ② 새 목표를 차팅해 티켓을 만든다 — **스크립트는 다시 띄우지 않는다**: autolaunch의 범위(번호 ≥ min)에 새 티켓이 자동으로 들어간다 ③ wake가 끝나 있으면(백그라운드 작업 목록에 없으면) `wake.sh <min>`만 다시 띄운다. 스크립트가 하나도 없을 때만 셋 다 기동.

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
   bash $S/wake.sh <min>         # 미취합 종결 티켓 또는 정체 세션이 생기면 끝나며 메인을 깨움
   ```

   탭 = `<effort> #<번호>`, 에이전트 = `t<번호>`, 첫 입력 `/advisor fable`(`ORCH_FIRST_INPUT`로 변경) → 작업 프롬프트.
   **Fable을 못 쓰면 Opus**(`ORCH_ADVISOR_FALLBACK`, 기본 `/advisor opus`): 기동 때 응답이 `Advisor set to`가 아니면 곧바로 바꾸고, 도는 중 Fable advisor 호출이 한도·사용 불가로 실패한 세션은 autoclose가 idle/done일 때 1회 바꾼다(`.orchestra/advisor_fallback`). 메인 세션 자신의 advisor가 Fable로 안 되면 사용자에게 `/advisor opus`를 쳐 달라고 알린다.
   티켓 밖 작업: `bash $S/spawn.sh --raw <번호>r "<effort> #<번호>r" "<프롬프트>"` — 완료 판정은 `#<번호>`를 언급한 커밋.
4. **취합(깨어날 때마다)** — `wake.sh` 출력의 티켓마다:
   - resolution comment의 `Decisions 요지`를 지도 Decisions에 한 줄(링크는 이름으로), 승격된 fog는 Not yet specified에서 지운다. 지도 본문은 **고치기 직전에 새로 받아** 고친다.
   - `메인 세션:` 줄·문서 반영 요청 처리 → 커밋·푸시.
   - 새로 생긴 티켓을 다시 병렬 판정(2) — 충돌이면 blocking. 풀린 것은 autolaunch가 띄운다.
   - **정체(`stalled`)**: 세션이 티켓을 연 채 idle로 멈춘 것 — 그 탭 화면(`herdr agent read t<번호> --source recent-unwrapped`)과 코멘트를 읽고, 남은 것이 사용자 결정이면 사용자에게 묻고 답을 그 세션에 전하거나(질문창이 아닐 때만) 메인이 코멘트로 정리해 닫는다. 브라우저 확인만 남았으면 `verify:browser` 라벨을 붙여 닫는다.
   - **verify 큐**: `verify:browser` 라벨이 붙은 닫힌 티켓 = 브라우저 확인만 남은 것. 메인이 **한 번에 하나씩**(브라우저 프로필 공유) 코멘트의 "남은 브라우저 확인" 절차대로 확인 → 결과 코멘트 → 라벨 제거. 육안 판정은 스크린샷으로 사용자에게 묻는다. 문제가 나오면 새 구현 티켓.
   - 처리한 번호를 `.orchestra/consolidated`에 적고 `wake.sh <min>`을 다시 띄운다.
5. **종료** — 범위 안 열린 티켓이 skip 말고 0이면 autolaunch가, 남은 탭이 없으면 autoclose가 끝난다. `stop.sh`로 마무리하고 사용자에게 산출물(결정·커밋·문서·파생 티켓)을 표로 종합 보고.

## 안전 규칙

- **세션은 idle로 끝내지 않는다**(2026-09-24 사건 — 구현 3건이 "브라우저 확인 남음"으로 티켓을 연 채 멈춰, 사용자는 끝난 줄 알았고 autoclose·wake는 종결을 못 봤다). 브라우저 확인만 남으면 `verify:browser`로 닫고, 사용자 결정이 남으면 닫기 전에 AskUserQuestion. 그래도 멈추면 wake가 '정체'로 메인을 깨운다.
- 여러 세션이 **같은 작업 트리**를 쓴다 — 커밋은 `git commit -- <자기 경로>`(남이 스테이징한 변경이 섞이지 않게, 메인 포함), `git add`는 자기 파일만, `add -A`·`stash`·`checkout --`·`pull --rebase` 금지, fetch 후 push(거절되면 멈춤).
- 지도 본문은 메인만 고친다(동시 편집은 덮어쓰기).
- autoclose는 이름 `t<키>` + 탭 이름이 `#<키>`로 끝나는 것만 닫는다. blocked(질문창)는 닫지 않는다.
- 도는 세션(working/blocked)에 입력을 보내지 않는다 — 질문창에 보낸 키는 답이 된다.
- **세션 화면의 입력창 회색 문구는 사용자 입력이 아니다** — Claude Code의 추천 답변(prompt suggestion)이 `agent read` 텍스트에는 실제 입력과 똑같이 찍힌다(2026-09-24 오판). "미전송 입력이 있다"고 보고하지 말 것.
- **스크립트는 `stop.sh`로만 끈다** — Windows에서는 백그라운드 작업을 멈춰도 bash 자식이 살아남아 탭을 계속 띄운다. 스크립트를 고쳐 다시 띄울 때도 `stop.sh` 먼저.
- Windows 파이썬 출력의 `\r`은 `tr -d '\r'`로 벗긴다(스크립트에 반영됨).
- Git Bash는 `/`로 시작하는 인자를 Windows 경로로 바꾼다 — `/advisor fable`이 `C:/Program Files/Git/advisor fable`로 들어가 일반 프롬프트가 됐다(2026-09-24 발견). `lib.sh`가 `MSYS_NO_PATHCONV=1`을 켠다 — herdr로 슬래시 명령을 보내는 코드는 lib.sh를 거칠 것.

## 상태 파일 (`<리포>/.orchestra/`, gitignore 권장)

`launched`(띄운 키 — 다시 안 띄움) · `advisor_fallback`(Opus로 바꾼 세션) · `skip`(자동 기동 제외) · `consolidated`(취합 끝난 번호) · `stalled_reported`(정체 보고한 번호) · `extra/<번호>`(티켓별 추가 지시) · `orchestra.log`.
