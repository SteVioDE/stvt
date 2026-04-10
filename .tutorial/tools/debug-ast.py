#!/usr/bin/env python3
"""Print the AST structure of a source file for debugging."""
import sys
from pathlib import Path

import tree_sitter_language_pack as tslp

def print_tree(node, depth=0, max_depth=4):
    if depth > max_depth:
        return
    text_preview = ""
    if node.child_count == 0:
        t = node.text.decode("utf-8", errors="replace")
        if len(t) <= 40:
            text_preview = f" = {t!r}"
    print("  " * depth + node.type + text_preview)
    for child in node.children:
        print_tree(child, depth + 1, max_depth)

lang = sys.argv[1]
filepath = sys.argv[2]
max_depth = int(sys.argv[3]) if len(sys.argv) > 3 else 4

parser = tslp.get_parser(lang)
source = Path(filepath).read_bytes()
tree = parser.parse(source)
print_tree(tree.root_node, max_depth=max_depth)
