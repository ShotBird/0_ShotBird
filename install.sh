#!/bin/bash
# skills/* 를 ~/.claude/skills/ 에 심볼릭 링크로 연결한다.
root="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.claude/skills"
mkdir -p "$dest"
for d in "$root"/skills/*/; do
  name=$(basename "$d"); link="$dest/$name"
  if [ -e "$link" ]; then echo "건너뜀(이미 있음): $link"; continue; fi
  ln -s "${d%/}" "$link" && echo "연결: $link -> ${d%/}"
done
