#!/usr/bin/env bash
FILE=".tutorial/next-chapter.md"
ERRORS=()

# Rule 1: Code fences max 3 lines
while IFS= read -r line; do
  ERRORS+=("$line")
done < <(awk '
/^```/{in_fence=1; fence_lines=0; fence_start=NR; next}
in_fence && /^```/{
  if(fence_lines > 3){printf "Line %d: Code fence with %d lines (max 3)\n", fence_start, fence_lines}
  in_fence=0; next
}
in_fence{fence_lines++}
' "$FILE")

# Rule 2: No Objective-C import patterns
while IFS= read -r line; do
  ERRORS+=("$line")
done < <(grep -n '^\s*#import\|^\s*#include' "$FILE" | sed 's/^/Import detected — line /')

# Rule 3: No interface/implementation definitions
while IFS= read -r line; do
  ERRORS+=("$line")
done < <(grep -nE '^\s*@interface|^\s*@implementation' "$FILE" | sed 's/^/Definition detected — line /')

# Rule 4: Max 500 lines
LINES=$(wc -l < "$FILE")
if [ "$LINES" -gt 500 ]; then
  ERRORS+=("Document is $LINES lines (max 500)")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "VALIDATION FAILED — ${#ERRORS[@]} violation(s):"
  echo ""
  for err in "${ERRORS[@]}"; do
    echo "  ✗ $err"
  done
  echo ""
  echo "Regenerate next-chapter.md with stricter abstraction."
  exit 1
fi
echo "Validated OK."
exit 0
