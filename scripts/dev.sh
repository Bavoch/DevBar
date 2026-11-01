#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

action="${1:-sync}"
case "$action" in
  sync) exec python3 scripts/watch-dev.py ;;
  status|stop)
    exec python3 scripts/watch-dev.py "$action"
    ;;
  *) print -u2 "未知开发操作：$action"; exit 1 ;;
esac
