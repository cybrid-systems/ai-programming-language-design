#!/usr/bin/env bash
# Linux Kernel Analysis - resumable per-file processor
# Runs forever, processes one file at a time with checkpointing
# Usage: ./process_one.sh [start_file_index]
#
# Output:
#   ~/code/ai-programming-language-design/linux-symbols/
#     symbols.jsonl   - one JSON per symbol with callers
#     .progress       - current file index
#     .files          - list of all files being processed

set -euo pipefail

KERNEL="$HOME/code/linux"
OUT="$HOME/code/ai-programming-language-design/linux-symbols"
SKILL="$HOME/code/workspace/skills/doom-lsp"
DOOM_Q="$SKILL/scripts/doom-query.sh"
TIMEOUT=25  # seconds per doom-query call

mkdir -p "$OUT"

# ── File list ──────────────────────────────────────────────────────────
# Extract kernel/mm/fs .c files from compile_commands.json
if [ ! -f "$OUT/.files" ]; then
    echo "Building file manifest from compile_commands.json..."
    python3 -c "
import json, sys
cc = json.load(open('$KERNEL/compile_commands.json'))
files = []
for e in cc:
    f = e['file']
    rel = f.replace('$KERNEL/', '')
    if (rel.startswith('kernel/') or rel.startswith('mm/') or rel.startswith('fs/')) and rel.endswith('.c'):
        files.append(rel)
files.sort()
for f in files: print(f)
" > "$OUT/.files"
fi

# Count total
TOTAL=$(wc -l < "$OUT/.files")
echo "Total files to process: $TOTAL"

# ── Get starting index ─────────────────────────────────────────────────
START_IDX=${1:-$(cat "$OUT/.progress" 2>/dev/null || echo 0)}
echo "Starting from index: $START_IDX"

# ── Pre-warm the daemon ────────────────────────────────────────────────
echo "Warming daemon..."
"$DOOM_Q" "$KERNEL" ping > /dev/null 2>&1 || true

# ── Main loop ──────────────────────────────────────────────────────────
IDX=$START_IDX
while IFS= read -r filepath; do
    if [ $IDX -lt $START_IDX ]; then
        IDX=$((IDX + 1))
        continue
    fi
    
    echo "[$IDX/$TOTAL] $filepath"
    
    # Get file symbols via doom-query summary (fast, text output)
    # Use timeout to avoid hangs
    SUMMARY=$(timeout $TIMEOUT "$DOOM_Q" "$KERNEL" summary "$filepath" 2>/dev/null || echo "")
    
    if [ -z "$SUMMARY" ]; then
        echo "  SKIP (no summary)"
        echo "$IDX" > "$OUT/.progress"
        IDX=$((IDX + 1))
        continue
    fi
    
    # Parse function names from summary output
    # Format: "  fn getKVStoreIndexForKey @ 39"
    FUNCTIONS=$(echo "$SUMMARY" | grep -oP 'fn \K[a-zA-Z_][a-zA-Z0-9_]+' | sort -u)
    
    for FN in $FUNCTIONS; do
        # Get callers for each function
        CALLERS=$(timeout $TIMEOUT "$DOOM_Q" "$KERNEL" callers "$FN" 2>/dev/null || echo "[]")
        
        # Write to JSONL (we parse the callers JSON from doom-query output)
        python3 -c "
import json, sys
callers_raw = '''$CALLERS'''
try:
    data = json.loads(callers_raw)
    callers = []
    if isinstance(data, dict):
        for s in data.get('call_sites', []):
            if s.get('kind') == 'call':
                callers.append('{}:{}'.format(s.get('file',''), s.get('line','')))
    print(json.dumps({
        'file': '$filepath',
        'symbol': '$FN',
        'callers': callers
    }))
except:
    print(json.dumps({'file': '$filepath', 'symbol': '$FN', 'callers': [], 'parse_error': True}))
" >> "$OUT/symbols.jsonl"
    done
    
    # Checkpoint
    echo "$IDX" > "$OUT/.progress"
    
    # Log progress every 10 files
    if [ $((IDX % 10)) -eq 0 ]; then
        echo "--- checkpoint $IDX ---" >&2
    fi
    
    IDX=$((IDX + 1))
    
done < "$OUT/.files"

echo "=== DONE ===" >&2
echo "Processed $TOTAL files" >&2