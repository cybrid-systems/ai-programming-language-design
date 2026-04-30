#!/usr/bin/env bash
# Runner for Linux kernel doom-lsp analysis
# Usage: ./run_linux_analysis.sh 2>&1 | tee analysis.log

KERNEL_DIR="$HOME/code/linux"
OUTPUT_DIR="$HOME/code/ai-programming-language-design/linux-symbols"
SKILL_DIR="$HOME/code/workspace/skills/doom-lsp"
LOG="$OUTPUT_DIR/analysis.log"

mkdir -p "$OUTPUT_DIR"
echo "$(date): Starting" >> "$LOG"

cd "$SKILL_DIR"
racket scripts/analyze-linux-lsp.rkt 2>&1 | tee -a "$LOG"
echo "$(date): Done" >> "$LOG"