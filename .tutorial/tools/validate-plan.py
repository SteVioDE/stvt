#!/usr/bin/env python3
"""
Validate plan.md against reference-inventory.json.

Checks:
  1. Every inventory symbol is assigned to exactly one chapter.
  2. No phantom symbols (plan references that don't exist in inventory).
  3. depends_on entries point to symbols in earlier chapters.
  4. Every inventory dependency is satisfied by an earlier chapter.

Usage:
    python validate-plan.py \
        --plan .tutorial/plan.md \
        --inventory .tutorial/reference-inventory.json
"""

import argparse
import json
import re
import sys
from pathlib import Path


# ─── Plan.md parser ──────────────────────────────────────────────────────────

def parse_plan(plan_text):
    """Parse plan.md into structured data.

    Returns:
        {
            "meta": {"project": ..., "total_chapters": ..., ...},
            "chapters": [
                {
                    "number": 1,
                    "title": "...",
                    "status": "planned",
                    "reference_scope": {"file.zig": ["Sym1", "Sym2"], ...},
                    "acquire_scope": ["path1", "path2"],
                    "depends_on": {"ch01": ["Sym1"], ...},
                },
                ...
            ]
        }
    """
    lines = plan_text.split("\n")
    sections = _split_sections(lines)

    meta = {}
    chapters = []

    for heading, body_lines in sections:
        if heading.lower().startswith("meta"):
            meta = _parse_kv_block(body_lines)
        else:
            match = re.match(r"Chapter\s+(\d+):\s*(.*)", heading)
            if match:
                ch_num = int(match.group(1))
                ch_title = match.group(2).strip()
                ch_data = _parse_chapter(body_lines)
                ch_data["number"] = ch_num
                ch_data["title"] = ch_title
                chapters.append(ch_data)

    return {"meta": meta, "chapters": chapters}


def _split_sections(lines):
    """Split on '## ' headers. Returns [(heading, [body_lines]), ...]."""
    sections = []
    current_heading = None
    current_body = []

    for line in lines:
        if line.startswith("## "):
            if current_heading is not None:
                sections.append((current_heading, current_body))
            current_heading = line[3:].strip()
            current_body = []
        elif current_heading is not None:
            current_body.append(line)

    if current_heading is not None:
        sections.append((current_heading, current_body))

    return sections


def _parse_chapter(lines):
    """Parse a chapter section's body lines."""
    data = {
        "status": "planned",
        "reference_scope": {},
        "acquire_scope": [],
        "depends_on": {},
    }

    current_key = None

    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        # Top-level key: "- key: value" or "- key:"
        top_match = re.match(r"^-\s+(\w+):\s*(.*)", stripped)
        if top_match:
            key = top_match.group(1)
            value = top_match.group(2).strip()
            current_key = key

            if key == "status":
                data["status"] = value
            elif key == "languages":
                data["languages"] = _parse_inline_list(value)
            elif key == "learning_goals":
                data.setdefault("learning_goals", [])
                if value:
                    data["learning_goals"].append(value)
            elif key in ("reference_scope", "acquire_scope", "depends_on"):
                # Value may be on the same line or on subsequent indented lines
                if value:
                    _add_scope_entry(data, key, value)
            continue

        # Indented continuation: "  - value"
        indent_match = re.match(r"^\s+-\s+(.*)", stripped)
        if indent_match and current_key:
            value = indent_match.group(1).strip()
            if current_key == "learning_goals":
                data.setdefault("learning_goals", [])
                data["learning_goals"].append(value)
            elif current_key in ("reference_scope", "acquire_scope", "depends_on"):
                _add_scope_entry(data, current_key, value)

    return data


def _add_scope_entry(data, key, value):
    """Add a single entry to reference_scope, acquire_scope, or depends_on."""
    if key == "reference_scope":
        # Format: "path/to/file: [Sym1, Sym2]" or "path/to/file"
        scope_match = re.match(r"(.+?):\s*\[(.+)\]", value)
        if scope_match:
            file_path = scope_match.group(1).strip()
            symbols = [s.strip() for s in scope_match.group(2).split(",")]
            data["reference_scope"].setdefault(file_path, [])
            data["reference_scope"][file_path].extend(symbols)
        else:
            # Bare file path = whole-file scope
            data["reference_scope"][value.strip()] = None  # None = whole file

    elif key == "acquire_scope":
        data["acquire_scope"].append(value.strip())

    elif key == "depends_on":
        # Format: "ch01: [Sym1, Sym2]"
        dep_match = re.match(r"(ch\d+):\s*\[(.+)\]", value)
        if dep_match:
            ch_ref = dep_match.group(1)
            symbols = [s.strip() for s in dep_match.group(2).split(",")]
            data["depends_on"].setdefault(ch_ref, [])
            data["depends_on"][ch_ref].extend(symbols)


def _parse_inline_list(value):
    """Parse '[item1, item2]' into a list."""
    match = re.match(r"\[(.+)\]", value)
    if match:
        return [s.strip() for s in match.group(1).split(",")]
    return [value] if value else []


def _parse_kv_block(lines):
    """Parse simple '- key: value' lines into a dict."""
    result = {}
    for line in lines:
        m = re.match(r"^\s*-\s+(\w+):\s*(.*)", line.strip())
        if m:
            result[m.group(1)] = m.group(2).strip()
    return result


# ─── Inventory loader ────────────────────────────────────────────────────────

def load_inventory(path):
    """Load reference-inventory.json."""
    with open(path) as f:
        return json.load(f)


# ─── Expand whole-file scopes ────────────────────────────────────────────────

def expand_scope(reference_scope, inventory):
    """Expand bare file paths to all symbols in that file from inventory.

    Returns dict: {file_path: [symbol_names]}
    """
    expanded = {}
    for file_path, symbols in reference_scope.items():
        if symbols is None:
            # Whole-file scope — expand to all inventory symbols in this file
            file_symbols = [
                name for name, sym in inventory["symbols"].items()
                if sym["file"] == file_path
            ]
            expanded[file_path] = file_symbols
        else:
            expanded[file_path] = list(symbols)
    return expanded


# ─── Validation checks ──────────────────────────────────────────────────────

def check_coverage(chapters, inventory):
    """Check 1: Every inventory symbol assigned to exactly one chapter."""
    issues = []
    # Map symbol → list of chapters it appears in
    symbol_chapters = {}

    for ch in chapters:
        expanded = expand_scope(ch["reference_scope"], inventory)
        for file_path, symbols in expanded.items():
            for sym in symbols:
                symbol_chapters.setdefault(sym, []).append(ch["number"])

    inventory_names = set(inventory["symbols"].keys())

    # Missing: in inventory but not in any chapter
    assigned = set(symbol_chapters.keys())
    missing = inventory_names - assigned
    for sym in sorted(missing):
        issues.append(f"Symbol '{sym}' is in inventory but not assigned to any chapter")

    # Duplicated: in multiple chapters
    for sym, chs in sorted(symbol_chapters.items()):
        if len(chs) > 1:
            ch_list = " AND ".join(f"Chapter {c:02d}" for c in chs)
            issues.append(f"Symbol '{sym}' assigned to multiple chapters: {ch_list}")

    return issues


def check_phantoms(chapters, inventory):
    """Check 2: Every symbol in plan exists in inventory."""
    issues = []
    inventory_names = set(inventory["symbols"].keys())

    for ch in chapters:
        for file_path, symbols in ch["reference_scope"].items():
            if symbols is None:
                continue  # Whole-file scope — already validated by file presence
            for sym in symbols:
                if sym not in inventory_names:
                    issues.append(
                        f"Phantom symbol '{sym}' in Chapter {ch['number']:02d} "
                        f"— not found in inventory"
                    )

    return issues


def check_depends_on_ordering(chapters, inventory):
    """Check 3: depends_on references point to symbols in earlier chapters."""
    issues = []
    # Build map: symbol → chapter number
    sym_to_chapter = {}
    for ch in chapters:
        expanded = expand_scope(ch["reference_scope"], inventory)
        for file_path, symbols in expanded.items():
            for sym in symbols:
                sym_to_chapter[sym] = ch["number"]

    for ch in chapters:
        for ch_ref, dep_symbols in ch["depends_on"].items():
            # Extract chapter number from "ch01"
            ref_num = int(re.search(r"\d+", ch_ref).group())
            if ref_num >= ch["number"]:
                issues.append(
                    f"Chapter {ch['number']:02d} depends_on references "
                    f"{ch_ref} [{', '.join(dep_symbols)}] (not earlier)"
                )
                continue

            for sym in dep_symbols:
                if sym not in sym_to_chapter:
                    issues.append(
                        f"Chapter {ch['number']:02d} depends_on references "
                        f"'{sym}' which is not assigned to any chapter"
                    )
                elif sym_to_chapter[sym] != ref_num:
                    issues.append(
                        f"Chapter {ch['number']:02d} depends_on says '{sym}' "
                        f"is in {ch_ref}, but it's actually in "
                        f"Chapter {sym_to_chapter[sym]:02d}"
                    )

    return issues


def check_dependency_completeness(chapters, inventory):
    """Check 4: Every inventory dependency is in an earlier chapter.

    For each symbol in chapter N, check its depends_on from the inventory.
    Each dependency must be assigned to a chapter < N.
    """
    issues = []
    # Build map: symbol → chapter number
    sym_to_chapter = {}
    for ch in chapters:
        expanded = expand_scope(ch["reference_scope"], inventory)
        for file_path, symbols in expanded.items():
            for sym in symbols:
                sym_to_chapter[sym] = ch["number"]

    for ch in chapters:
        expanded = expand_scope(ch["reference_scope"], inventory)
        for file_path, symbols in expanded.items():
            for sym_name in symbols:
                inv_sym = inventory["symbols"].get(sym_name)
                if not inv_sym:
                    continue
                for dep in inv_sym.get("depends_on", []):
                    dep_chapter = sym_to_chapter.get(dep)
                    if dep_chapter is None:
                        # Dependency not in any chapter — might be external
                        continue
                    if dep_chapter > ch["number"]:
                        issues.append(
                            f"'{sym_name}' (Chapter {ch['number']:02d}) depends on "
                            f"'{dep}' (Chapter {dep_chapter:02d}) — "
                            f"dependency comes later"
                        )
                    elif dep_chapter == ch["number"]:
                        # Same chapter — acceptable (taught together)
                        pass

    return issues


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Validate plan.md against reference-inventory.json."
    )
    parser.add_argument("--plan", required=True, help="Path to plan.md")
    parser.add_argument("--inventory", required=True, help="Path to reference-inventory.json")
    parser.add_argument("--partial", action="store_true",
                        help="Skip coverage check — use during progressive plan writing")

    args = parser.parse_args()

    plan_text = Path(args.plan).read_text()
    inventory = load_inventory(args.inventory)
    plan = parse_plan(plan_text)

    chapters = plan["chapters"]
    if not chapters:
        print("ERROR: No chapters found in plan.md", file=sys.stderr)
        sys.exit(1)

    print(f"PLAN VALIDATION — {args.inventory} vs {args.plan}\n")

    all_issues = []

    # Check 1: Coverage
    if args.partial:
        print(f"\u2298 Coverage check skipped (--partial mode)")
    else:
        issues = check_coverage(chapters, inventory)
        all_issues.extend(issues)
        if issues:
            n = len(issues)
            print(f"\u2717 {n} coverage issue(s):")
            for i in issues:
                print(f"    {i}")
        else:
            inv_count = len(inventory["symbols"])
            print(f"\u2713 All {inv_count} inventory symbols assigned to chapters")

    # Check 2: Phantoms
    issues = check_phantoms(chapters, inventory)
    all_issues.extend(issues)
    if issues:
        n = len(issues)
        print(f"\u2717 {n} phantom symbol(s):")
        for i in issues:
            print(f"    {i}")
    else:
        print(f"\u2713 No phantom symbols in plan")

    # Check 3: depends_on ordering
    issues = check_depends_on_ordering(chapters, inventory)
    all_issues.extend(issues)
    if issues:
        n = len(issues)
        print(f"\u2717 {n} depends_on ordering issue(s):")
        for i in issues:
            print(f"    {i}")
    else:
        print(f"\u2713 All depends_on references point to earlier chapters")

    # Check 4: Dependency completeness
    issues = check_dependency_completeness(chapters, inventory)
    all_issues.extend(issues)
    if issues:
        n = len(issues)
        print(f"\u2717 {n} missing dependency declaration(s):")
        for i in issues:
            print(f"    {i}")
    else:
        print(f"\u2713 All inventory dependencies satisfied by chapter ordering")

    print()
    if all_issues:
        print(f"RESULT: FAILED — {len(all_issues)} issue(s) found")
        sys.exit(1)
    else:
        print("RESULT: PASSED")
        sys.exit(0)


if __name__ == "__main__":
    main()
