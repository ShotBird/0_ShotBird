#!/bin/bash
# 사용: stop.sh   — 오케스트라 스크립트(autolaunch·autoclose·wake)를 PID로 끝낸다. 띄운 탭은 그대로 둔다.
# Windows(Git Bash)에서는 Claude Code 백그라운드 작업을 멈춰도 bash 자식이 살아남는다 — 그래서 ps로 찾아 죽인다.
# 리포 안에 사본을 둔 경우(docs/agents/orchestra/)도 함께 잡는다.
pids=$(ps -ef | grep -E "(orchestra|shotbird)/(scripts/)?(autolaunch|autoclose|wake)\.sh" | grep -v grep | awk '{print $2}')
[ -z "$pids" ] && { echo "도는 오케스트라 스크립트 없음"; exit 0; }
kill $pids && echo "종료: $pids"
