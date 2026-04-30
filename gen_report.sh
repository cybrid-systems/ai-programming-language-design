#!/usr/bin/env bash
# Generate report from collected symbols
# Run after process_one.sh has collected symbols.jsonl

OUT="$HOME/code/ai-programming-language-design/linux-symbols"

echo "=== Generating Report ==="

if [ ! -f "$OUT/symbols.jsonl" ]; then
    echo "ERROR: symbols.jsonl not found"
    exit 1
fi

python3 -c "
import json
from collections import defaultdict

symbols = []
with open('$OUT/symbols.jsonl') as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                symbols.append(json.loads(line))
            except:
                pass

files = set()
unique_syms = set()
edges = 0
by_file = defaultdict(list)

for s in symbols:
    files.add(s['file'])
    unique_syms.add(s['symbol'])
    by_file[s['file']].append(s['symbol'])
    edges += len(s.get('callers', []))

print(f'Files: {len(files)}')
print(f'Symbols: {len(unique_syms)}')
print(f'Edges: {edges}')

# Top files by symbol count
by_count = sorted(by_file.items(), key=lambda x: -len(x[1]))
print()
print('Top 20 files by symbol count:')
for f, syms in by_count[:20]:
    print(f'  {len(syms):4d} {f}')

# Symbol caller distribution
caller_counts = [len(s.get('callers', [])) for s in symbols]
print()
print(f'Caller distribution:')
print(f'  max: {max(caller_counts)}')
print(f'  avg: {sum(caller_counts)/len(caller_counts):.1f}')
print(f'  symbols with callers: {sum(1 for c in caller_counts if c > 0)}')
print(f'  symbols without callers: {sum(1 for c in caller_counts if c == 0)}')
" 2>&1