#!/bin/bash
# 자동 점검용 가짜 Claude Code(WSL 안에 둔다)
#  --version        : 버전
#  -p …             : 표준 입력과 --system-prompt 를 보고 한 줄 답
#  그 밖(세션)      : --settings 의 Stop 훅(윈도 실행 파일)을 불러 세션 상태를 남기고 기다린다
if [ "$1" = "--version" ]; then echo "9.9.9 (fake Claude Code)"; exit 0; fi
if [ "$1" = "-p" ]; then
  sys=""
  while [ $# -gt 0 ]; do
    if [ "$1" = "--system-prompt" ]; then sys="$2"; fi
    shift
  done
  input=$(cat)
  file=$(printf '%s' "$input" | grep -o 'b/[^ ]*' | head -1)
  printf 'WSL 커밋: %s / %s\n' "$(printf '%s' "$sys" | head -c 13)" "$file"
  exit 0
fi
settings=""
mode=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--settings" ]; then settings="$2"; fi
  if [ "$1" = "--permission-mode" ]; then mode="$2"; fi
  shift
done
cmd=$(grep -o '"command": "[^"]*--agent-hook Stop"' "$settings" | sed 's/^"command": "//; s/"$//')
echo '{"session_id":"wsl-test"}' | sh -c "$cmd"
echo "FAKE CLAUDE SESSION OK pwd=$(pwd) agent=$GITROCHI_AGENT_ID mode=$mode"
sleep 60
