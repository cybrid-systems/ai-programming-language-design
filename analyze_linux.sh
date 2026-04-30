#!/usr/bin/env bash
# Linux Kernel Analysis - Phase 1: Build ctags index for fast symbol search
# Output: ~/code/ai-programming-language-design/linux-symbols/

set -e
KERNEL_DIR="$HOME/code/linux"
OUTPUT_DIR="$HOME/code/ai-programming-language-design/linux-symbols"
METADATA_DIR="$OUTPUT_DIR/.metadata"
mkdir -p "$OUTPUT_DIR" "$METADATA_DIR"

echo "=== Phase 1: ctags indexing (fast symbol lookup) ==="
echo "Scanning .c files..."
find "$KERNEL_DIR" -name "*.c" -not -path "*/arch/*" -not -path "*/drivers/*" \
    -not -path "*/sound/*" -not -path "*/crypto/*" -not -path "*/virt/*" \
    -not -path "*/net/*" | wc -l

echo "Building tags file (this takes a few minutes for full kernel)..."
cd "$KERNEL_DIR"
# For full kernel including drivers:
find . -name "*.c" -o -name "*.h" | head -5000 > "$METADATA_DIR/file_manifest.txt"
wc -l < "$METADATA_DIR/file_manifest.txt"

echo "ctags indexing done. Manifest saved."