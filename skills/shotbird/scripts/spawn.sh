#!/bin/bash
# 사용: spawn.sh <번호> [추가 지시]              — 이슈 1개를 herdr 탭으로 띄운다(종류는 라벨로 판정)
#       spawn.sh --raw <키> <탭이름> <프롬프트>    — 이슈 밖 작업(예: 닫힌 이슈의 후속 정정, 키 "286r")
. "$(dirname "$0")/lib.sh"
require_herdr
if [ "$1" = --raw ]; then spawn "$2" "$3" "$4"; else spawn_ticket "$1" "$2"; fi
tail -1 "$LOG"
