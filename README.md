# 0_ShotBird

Claude Code 전역 스킬 모음.

## `/shotbird` — 병렬 오케스트라

메인 Claude 세션이 오케스트라를 맡는다. 먼저 GitHub Issues에 지도와 티켓을 정의한다(wayfinder 규약(mattpocock-skills)). 그다음 herdr 탭마다 Claude 세션을 하나씩 띄워 티켓을 병렬로 결정하거나 구현한다.

- **자동 기동**: `autolaunch.sh`가 frontier 티켓을 탭으로 띄운다. frontier는 열려 있고, 담당자가 없고, blocker가 없는 티켓이다.
- **자동 닫기**: `autoclose.sh`가 티켓이 닫히고 세션이 idle 상태면 그 탭을 닫는다.
- **메인 깨우기**: `wake.sh`는 티켓이 닫히면 끝나면서 메인 세션을 깨운다. 메인은 결과를 모으고, 이어지는 티켓을 정의한 뒤 다시 돌린다.

자세한 절차는 [`skills/shotbird/SKILL.md`](skills/shotbird/SKILL.md)에 있다.

### 전제

- herdr 안에서 실행한다(`HERDR_ENV=1`).
- `gh` CLI에 로그인되어 있어야 한다.
- 대상 리포는 GitHub Issues를 쓰고, sub-issue와 issue dependency 기능이 켜져 있어야 한다.
- Git Bash(Windows) 또는 bash, 그리고 python이 필요하다.

### 설치

```powershell
# Windows: 리포 폴더를 전역 스킬 폴더에 junction으로 연결 (리포를 고치면 바로 반영)
powershell -ExecutionPolicy Bypass -File install.ps1
```

```bash
# macOS/Linux
./install.sh
```

설치하면 `~/.claude/skills/shotbird`가 생긴다. 새 Claude Code 세션에서 `/shotbird <목표>`로 부른다.
