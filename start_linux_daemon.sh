#!/usr/bin/env bash
# Start a persistent Linux kernel clangd daemon in the background
# Then communicate with it via FIFO

KERNEL="$HOME/code/linux"
SKILL="$HOME/code/workspace/skills/doom-lsp"
CACHE="$HOME/.cache/doom-lsp"
mkdir -p "$CACHE"

# Kill any existing daemon first
ps aux | grep "[c]langd.rkt -d $KERNEL DAEMONMODE" | grep -v grep | awk '{print $2}' | xargs -r kill 2>/dev/null
sleep 1

# Start daemon, background it, wait for READY
cd "$SKILL"
echo "Starting daemon for Linux kernel..."
./scripts/doom-lsp.sh "$KERNEL" daemon start 2>&1
sleep 3

# Verify it's running
if ps aux | grep -q "[c]langd.rkt -d $KERNEL DAEMONMODE" | grep -v grep; then
    echo "Daemon started successfully"
else
    echo "Daemon failed to start"
fi