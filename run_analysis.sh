#!/usr/bin/env bash
# Linux Kernel Analysis - doom-lsp batch runner
# Usage: ./run_analysis.sh [start_idx]
# Resumable: checkpoints after every 50 files

KERNEL_DIR="$HOME/code/linux"
OUTPUT_DIR="$HOME/code/ai-programming-language-design/linux-symbols"
SKILL_DIR="$HOME/code/workspace/skills/doom-lsp"
BATCH=50

mkdir -p "$OUTPUT_DIR"

echo "=== Starting doom-lsp Linux analysis ==="
echo "Output: $OUTPUT_DIR"
echo "Progress: $OUTPUT_DIR/.progress"
echo ""

# Check compile_commands.json
if [ ! -f "$KERNEL_DIR/compile_commands.json" ]; then
    echo "ERROR: compile_commands.json not found"
    exit 1
fi

# Run the Racket analysis script
cd "$SKILL_DIR"
exec racket -N analysis -t scripts/pool.rkt \
    -e "(current-directory \"$SKILL_DIR\")" \
    -e "(require \"scripts/pool.rkt\")" \
    -e "(require \"scripts/analyze-linux-batch.rkt\")" \
    -e "(main)" 2>&1