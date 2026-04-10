#!/usr/bin/env bash
# check-deps.sh — SessionStart hook for the stevio-tutorial plugin.
#
# Checks whether tree-sitter tools can run and reports the result
# as context that Claude sees at session start.

set -euo pipefail

ISSUES=()

# Check for Python 3
if ! command -v python3 &>/dev/null && ! command -v python &>/dev/null; then
    ISSUES+=("Python 3 is not installed. The tree-sitter tools in /stevio-init and /stevio-done require Python.")
fi

# Check for uv (preferred) or pip (fallback)
HAS_UV=false
HAS_PIP=false

if command -v uv &>/dev/null; then
    HAS_UV=true
fi

PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" &>/dev/null; then
        PYTHON="$candidate"
        break
    fi
done

if [ -n "$PYTHON" ] && "$PYTHON" -m pip --version &>/dev/null 2>&1; then
    HAS_PIP=true
fi

# Check if tree-sitter is already available
TS_AVAILABLE=false
if [ -n "$PYTHON" ] && "$PYTHON" -c "import tree_sitter; import tree_sitter_language_pack" 2>/dev/null; then
    TS_AVAILABLE=true
fi

# Build status message
if $TS_AVAILABLE; then
    echo "stevio-tutorial: tree-sitter dependencies are available. All tools ready."
elif $HAS_UV; then
    echo "stevio-tutorial: uv found. Tree-sitter dependencies will be installed automatically when /stevio-init runs."
elif $HAS_PIP; then
    echo "stevio-tutorial: pip found. Tree-sitter dependencies will be installed into a local .venv when /stevio-init runs. Note: this requires network access — if running in sandbox mode, the user may need to pre-install: pip install tree-sitter tree-sitter-language-pack"
else
    ISSUES+=("Neither uv nor pip found. Cannot auto-install tree-sitter dependencies.")
fi

if [ ${#ISSUES[@]} -gt 0 ]; then
    echo "stevio-tutorial dependency warnings:"
    for issue in "${ISSUES[@]}"; do
        echo "  - $issue"
    done
fi

exit 0
