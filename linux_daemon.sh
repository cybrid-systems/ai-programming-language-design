#!/usr/bin/env bash
# Direct IPC with the Linux clangd daemon via FIFO
# Usage: ./linux_daemon.sh <command> [args...]

set -euo pipefail

DOOM_DIR="$HOME/code/workspace/skills/doom-lsp"
DAEMON_PID=$(ps aux | grep "[c]langd.rkt -d $HOME/code/linux DAEMONMODE" | awk '{print $2}' | head -1)

if [ -z "$DAEMON_PID" ]; then
    echo "ERROR: No Linux clangd daemon running"
    exit 1
fi

# Find the FIFO
FIFO=$(ls /tmp/doom-lsp-linux/fifo 2>/dev/null || echo "")
if [ -z "$FIFO" ] || [ ! -p "$FIFO" ]; then
    echo "ERROR: FIFO not found at /tmp/doom-lsp-linux/fifo"
    exit 1
fi

CMD="$1"
shift

case "$CMD" in
    ping)
        echo "ping" > "$FIFO"
        sleep 0.5
        grep -m1 "pong\|READY" /tmp/doom-lsp-linux/out 2>/dev/null | tail -1
        ;;
    sym)
        QUERY="$1"
        echo "sym $QUERY" > "$FIFO"
        sleep 2
        tail -20 /tmp/doom-lsp-linux/out 2>/dev/null
        ;;
    doc)
        FILE="$1"
        echo "doc $FILE" > "$FIFO"
        sleep 3
        tail -30 /tmp/doom-lsp-linux/out 2>/dev/null
        ;;
    def)
        FILE="$1"; LINE="$2"; COL="${3:-1}"
        echo "def $FILE $LINE $COL" > "$FIFO"
        sleep 3
        tail -5 /tmp/doom-lsp-linux/out 2>/dev/null
        ;;
    summary)
        FILE="$1"
        echo "doc $FILE" > "$FIFO"
        sleep 3
        python3 -c "
import json, sys
lines = open('/tmp/doom-lsp-linux/out').readlines()
for l in lines[-50:]:
    l = l.strip()
    if l.startswith('[') or l.startswith('{'):
        try:
            d = json.loads(l)
            if isinstance(d, list):
                for x in d:
                    name = x.get('name','?')
                    kind = x.get('kind', 0)
                    kind_names = ['?','?','?','?','?','cls','struct','?','field','','?','?','fn','var']
                    k = kind_names[kind] if kind < len(kind_names) else '?'
                    print(f'  {k} {name} @ {x.get(\"line\",\"?\")}')
        except: pass
" 2>/dev/null
        ;;
    *)
        echo "Usage: $0 {ping|sym|doc|def|summary} [args...]"
        exit 1
        ;;
esac