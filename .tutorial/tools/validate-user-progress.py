#!/usr/bin/env python3
"""
Validate reader's implementation against the chapter plan.

Checks that symbols expected from a chapter's reference_scope actually
exist in the reader's code and are not still stubs with EXERCISE markers.

Usage:
    python validate-user-progress.py \
        --source-dir . \
        --plan .tutorial/plan.md \
        --progress .tutorial/progress.md \
        --chapter 3
"""

import argparse
import re
import sys
from pathlib import Path

# Re-use the plan parser and inventory loader from sibling modules.
# To keep this script self-contained (it's copied into .tutorial/tools/),
# we inline the minimum parsing logic needed.


# ─── Plan.md parser (minimal, focused on reference_scope) ────────────────────

def parse_chapter_scope(plan_text, chapter_num):
    """Extract reference_scope for a specific chapter from plan.md.

    Returns dict: {file_path: [symbol_names] or None (whole file)}
    """
    lines = plan_text.split("\n")
    in_target = False
    current_key = None
    scope = {}

    chapter_pattern = re.compile(
        rf"^##\s+Chapter\s+0*{chapter_num}:", re.IGNORECASE
    )
    next_chapter = re.compile(r"^##\s+Chapter\s+\d+:", re.IGNORECASE)

    for line in lines:
        if chapter_pattern.match(line):
            in_target = True
            continue
        if in_target and next_chapter.match(line):
            break
        if not in_target:
            continue

        stripped = line.strip()
        top_match = re.match(r"^-\s+(\w+):\s*(.*)", stripped)
        if top_match:
            current_key = top_match.group(1)
            value = top_match.group(2).strip()
            if current_key == "reference_scope" and value:
                _add_scope(scope, value)
            continue

        indent_match = re.match(r"^\s+-\s+(.*)", stripped)
        if indent_match and current_key == "reference_scope":
            _add_scope(scope, indent_match.group(1).strip())

    return scope


def _add_scope(scope, value):
    match = re.match(r"(.+?):\s*\[(.+)\]", value)
    if match:
        file_path = match.group(1).strip()
        symbols = [s.strip() for s in match.group(2).split(",")]
        scope.setdefault(file_path, [])
        scope[file_path].extend(symbols)
    else:
        scope[value.strip()] = None


# ─── Progress.md parser (for user_approach / renames) ────────────────────────

def parse_user_renames(progress_text, chapter_num):
    """Extract symbol renames from progress.md user_approach field.

    Returns dict: {original_name: actual_name}
    """
    # Look for patterns like "renamed X to Y" or "X → Y" in user_approach
    renames = {}
    lines = progress_text.split("\n")
    in_chapter = False
    chapter_pattern = re.compile(
        rf"^##\s+Chapter\s+0*{chapter_num}:", re.IGNORECASE
    )

    in_approach = False
    for line in lines:
        if chapter_pattern.match(line):
            in_chapter = True
            continue
        if in_chapter and line.startswith("## "):
            break
        if not in_chapter:
            continue

        stripped = line.strip()
        # Detect start of user_approach field
        if re.match(r"^-\s+user_approach:", stripped, re.I):
            in_approach = True
        elif re.match(r"^-\s+\w+:", stripped):
            in_approach = False

        # Scan for rename indicators in user_approach lines
        if in_approach:
            for m in re.finditer(r"renamed?\s+(\w+)\s+(?:to|→|->)\s+(\w+)", line, re.I):
                renames[m.group(1)] = m.group(2)

    return renames


# ─── Tree-sitter symbol finder ───────────────────────────────────────────────

def find_definitions_in_file(file_path, expected_symbols):
    """Use tree-sitter to find symbol definitions in a source file.

    Returns:
        {
            "SymbolName": {
                "found": True/False,
                "line": int or None,
                "has_exercise_marker": True/False,
            }
        }
    """
    # Import here so the script fails gracefully if tree-sitter missing
    try:
        from tree_sitter_language_pack import get_parser
        _get_parser = get_parser
    except (ImportError, AttributeError):
        from tree_sitter import Parser
        from tree_sitter_language_pack import get_language
        def _get_parser(lang):
            return Parser(get_language(lang))

    ext = file_path.suffix.lower()
    lang = _ext_to_lang(ext)
    if not lang:
        return {sym: {"found": False, "line": None, "has_exercise_marker": False}
                for sym in expected_symbols}

    try:
        source = file_path.read_bytes()
    except FileNotFoundError:
        return {sym: {"found": False, "line": None, "has_exercise_marker": False}
                for sym in expected_symbols}

    parser = _get_parser(lang)
    tree = parser.parse(source)
    source_text = source.decode("utf-8", errors="replace")

    # Collect all definition names and their line ranges
    definitions = _collect_definitions(tree.root_node, source_text)

    results = {}
    for sym in expected_symbols:
        if sym in definitions:
            defn = definitions[sym]
            # Check for EXERCISE markers in the definition's text range
            body_text = source_text[defn["start"] : defn["end"]]
            has_marker = bool(re.search(r"(?://|#|/\*)\s*EXERCISE:", body_text))
            results[sym] = {
                "found": True,
                "line": defn["line"],
                "has_exercise_marker": has_marker,
            }
        else:
            results[sym] = {
                "found": False,
                "line": None,
                "has_exercise_marker": False,
            }

    return results


def _collect_definitions(node, source_text, prefix=""):
    """Walk AST and collect all definition names → {line, start, end}."""
    defs = {}
    for child in node.children:
        name = _try_get_name(child)
        if name and _is_definition(child):
            full_name = f"{prefix}.{name}" if prefix else name
            defs[full_name] = {
                "line": child.start_point[0] + 1,
                "start": child.start_byte,
                "end": child.end_byte,
            }
            # Also store bare name for flexible matching, but only if
            # no other bare-name entry exists (avoid cross-class collisions)
            if prefix and name not in defs:
                defs[name] = defs[full_name]
            # Recurse into containers (classes, impl blocks, etc.)
            if _is_container(child):
                defs.update(_collect_definitions(child, source_text, full_name))
        elif _is_container(child):
            cname = _try_get_name(child) or prefix
            defs.update(_collect_definitions(child, source_text, cname))
        else:
            # Recurse into other compound nodes
            if child.child_count > 0:
                defs.update(_collect_definitions(child, source_text, prefix))
    return defs


DEFINITION_TYPES = {
    "function_definition", "function_declaration", "function_item",
    "method_declaration", "method_definition",
    "class_definition", "class_declaration", "class_specifier",
    "struct_item", "struct_declaration", "struct_specifier",
    "enum_item", "enum_declaration", "enum_specifier",
    "interface_declaration", "trait_item", "protocol_declaration",
    "type_item", "type_alias_declaration", "type_definition", "typealias_declaration",
    "const_item", "static_item", "property_declaration",
    "variable_declaration", "object_declaration",
    "constructor_declaration",
    # Zig variants
    "FnProto", "VarDecl", "ContainerDecl",
    # ObjC
    "class_interface", "class_implementation",
}

CONTAINER_TYPES = {
    "class_definition", "class_declaration", "class_specifier", "class_body",
    "struct_declaration", "struct_specifier", "struct_body",
    "enum_declaration", "enum_body",
    "impl_item", "trait_item",
    "interface_declaration", "interface_body",
    "class_interface", "class_implementation",
    "object_declaration",
    "ContainerDecl", "container_declaration",
}


def _is_definition(node):
    return node.type in DEFINITION_TYPES


def _is_container(node):
    return node.type in CONTAINER_TYPES


def _try_get_name(node):
    """Try to extract a name from an AST node."""
    # Field-based access
    name_node = node.child_by_field_name("name")
    if name_node:
        return name_node.text.decode("utf-8")
    # Look for identifier children (common fallback)
    for child in node.children:
        if child.type in ("identifier", "type_identifier", "IDENTIFIER",
                          "simple_identifier"):
            return child.text.decode("utf-8")
    return None


EXT_LANG_MAP = {
    ".py": "python", ".zig": "zig", ".go": "go", ".rs": "rust",
    ".java": "java", ".kt": "kotlin", ".kts": "kotlin",
    ".ts": "typescript", ".tsx": "typescript", ".js": "javascript", ".jsx": "javascript",
    ".c": "c", ".h": "c", ".cpp": "cpp", ".cc": "cpp", ".cxx": "cpp",
    ".hpp": "cpp", ".hh": "cpp", ".m": "objc", ".mm": "objc", ".swift": "swift",
}


def _ext_to_lang(ext):
    return EXT_LANG_MAP.get(ext)


# ─── Main validation logic ──────────────────────────────────────────────────

def validate_chapter(source_dir, plan_text, progress_text, chapter_num):
    """Validate reader's implementation for a specific chapter.

    Returns list of (symbol, status, detail) tuples.
    """
    source_dir = Path(source_dir)
    scope = parse_chapter_scope(plan_text, chapter_num)
    renames = parse_user_renames(progress_text, chapter_num) if progress_text else {}

    results = []

    for file_path, symbols in scope.items():
        if symbols is None:
            # Whole-file scope — just check the file exists
            full_path = source_dir / file_path
            if full_path.exists():
                results.append((file_path, "pass", f"file exists at {file_path}"))
            else:
                results.append((file_path, "fail", f"file NOT FOUND: {file_path}"))
            continue

        # Build list of names to search for (including renames)
        search_names = {}
        for sym in symbols:
            actual_name = renames.get(sym, sym)
            search_names[sym] = actual_name

        full_path = source_dir / file_path
        check_results = find_definitions_in_file(
            full_path, list(search_names.values())
        )

        for original, actual in search_names.items():
            info = check_results.get(actual, {
                "found": False, "line": None, "has_exercise_marker": False,
            })
            if not info["found"]:
                results.append((
                    original, "fail",
                    f"NOT FOUND (expected in {file_path})"
                ))
            elif info["has_exercise_marker"]:
                results.append((
                    original, "fail",
                    f"contains EXERCISE marker (incomplete) at {file_path}:{info['line']}"
                ))
            else:
                rename_note = f" (as '{actual}')" if actual != original else ""
                results.append((
                    original, "pass",
                    f"found in {file_path}:{info['line']}{rename_note}"
                ))

    return results


# ─── CLI ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Validate reader's implementation for a tutorial chapter."
    )
    parser.add_argument("--source-dir", required=True, help="Reader's source directory")
    parser.add_argument("--plan", required=True, help="Path to plan.md")
    parser.add_argument("--progress", required=True, help="Path to progress.md")
    parser.add_argument("--chapter", required=True, type=int, help="Chapter number to validate")

    args = parser.parse_args()

    plan_text = Path(args.plan).read_text()
    progress_path = Path(args.progress)
    progress_text = progress_path.read_text() if progress_path.exists() else ""

    print(f"USER PROGRESS VALIDATION — Chapter {args.chapter:02d}\n")

    results = validate_chapter(args.source_dir, plan_text, progress_text, args.chapter)

    if not results:
        print("WARNING: No symbols found in plan for this chapter.", file=sys.stderr)
        sys.exit(1)

    failures = 0
    for sym, status, detail in results:
        icon = "\u2713" if status == "pass" else "\u2717"
        print(f"{icon} {sym} — {detail}")
        if status == "fail":
            failures += 1

    print()
    if failures:
        print(f"RESULT: FAILED — {failures} issue(s)")
        sys.exit(1)
    else:
        print("RESULT: PASSED")
        sys.exit(0)


if __name__ == "__main__":
    main()
