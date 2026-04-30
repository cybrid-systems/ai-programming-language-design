#!/usr/bin/env bash
# Run the Linux kernel analysis script
# Usage: ./run_linux.sh 2>&1 | tee logs.txt

set -e
KERNEL_DIR="$HOME/code/linux"
OUT_DIR="$HOME/code/ai-programming-language-design/linux-symbols"
SKILL_DIR="$HOME/code/workspace/skills/doom-lsp"
LOG="$OUT_DIR/run.log"

mkdir -p "$OUT_DIR" "$(dirname "$LOG")"
echo "$(date): Starting Linux kernel analysis" >> "$LOG"

cd "$SKILL_DIR/scripts"
racket linux-analysis.rkt 2>&1 | tee -a "$LOG"
echo "$(date): Done" >> "$LOG"