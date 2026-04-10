#!/usr/bin/env bash
# run-tool.sh — Run a Python tool with tree-sitter dependencies.
#
# Tries uv first (ephemeral cached env), falls back to a local .venv.
#
# Usage:
#   bash /path/to/run-tool.sh /path/to/script.py [args...]
#
# The TOOLS_DIR is auto-detected from this script's location.
# The .venv (if created) lives alongside this script at TOOLS_DIR/.venv/

set -euo pipefail

SCRIPT="$1"
shift

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
REQUIREMENTS="$TOOLS_DIR/requirements.txt"
VENV_DIR="$TOOLS_DIR/.venv"

# ─── Strategy 1: uv (fast, ephemeral, no persistent state) ───────────────────

if command -v uv &>/dev/null; then
    # Use a sandbox-writable cache dir if the default is blocked
    export UV_CACHE_DIR="${UV_CACHE_DIR:-${TMPDIR:-/tmp}/uv-cache}"
    exec uv run \
        --with tree-sitter \
        --with tree-sitter-language-pack \
        python "$SCRIPT" "$@"
fi

# ─── Strategy 2: local .venv with pip ────────────────────────────────────────

# Find a working python3
PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" &>/dev/null; then
        PYTHON="$candidate"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    echo "ERROR: No python3 or python found on PATH." >&2
    echo "Install Python 3 or uv (https://docs.astral.sh/uv/)." >&2
    exit 1
fi

# Create venv if it doesn't exist
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment at $VENV_DIR ..." >&2
    "$PYTHON" -m venv "$VENV_DIR"
fi

# Activate and install if needed
VENV_PYTHON="$VENV_DIR/bin/python"
if [ ! -f "$VENV_PYTHON" ]; then
    # Windows fallback
    VENV_PYTHON="$VENV_DIR/Scripts/python"
fi

if ! "$VENV_PYTHON" -c "import tree_sitter; import tree_sitter_language_pack" 2>/dev/null; then
    echo "Installing tree-sitter dependencies ..." >&2
    "$VENV_PYTHON" -m pip install --quiet -r "$REQUIREMENTS"
fi

exec "$VENV_PYTHON" "$SCRIPT" "$@"
