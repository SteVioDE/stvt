#!/usr/bin/env python3
"""
Extract symbol inventory from source files using tree-sitter.

Produces reference-inventory.json with every symbol definition,
its location, kind, visibility, and intra-project dependencies.

Usage:
    python extract-inventory.py \
        --root /path/to/project \
        --files src/main.zig src/types.zig \
        --output .tutorial/reference-inventory.json
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

TOOL_VERSION = "1.0.0"

# ─── File extension → language mapping ────────────────────────────────────────

EXT_TO_LANG = {
    ".zig": "zig", ".zon": "zig",
    ".py": "python",
    ".go": "go",
    ".rs": "rust",
    ".java": "java",
    ".kt": "kotlin", ".kts": "kotlin",
    ".ts": "typescript", ".tsx": "typescript",
    ".js": "javascript", ".jsx": "javascript",
    ".c": "c", ".h": "c",
    ".cpp": "cpp", ".cc": "cpp", ".cxx": "cpp",
    ".hpp": "cpp", ".hh": "cpp", ".hxx": "cpp",
    ".m": "objc", ".mm": "objc",
    ".swift": "swift",
}

# tree-sitter-language-pack grammar names (with fallbacks)
TS_LANG_NAMES = {
    "zig": ["zig"],
    "python": ["python"],
    "go": ["go"],
    "rust": ["rust"],
    "java": ["java"],
    "kotlin": ["kotlin"],
    "typescript": ["typescript", "tsx"],
    "javascript": ["javascript"],
    "c": ["c"],
    "cpp": ["cpp"],
    "swift": ["swift"],
    "objc": ["objc", "objective_c", "objective-c", "objectivec"],
}

# ─── Parser creation ──────────────────────────────────────────────────────────

_parser_cache = {}


def make_parser(lang):
    """Create a tree-sitter parser for the given language."""
    if lang in _parser_cache:
        return _parser_cache[lang]

    from tree_sitter_language_pack import get_language

    names = TS_LANG_NAMES.get(lang, [lang])
    last_err = None
    for name in names:
        try:
            ts_lang = get_language(name)
            break
        except Exception as e:
            last_err = e
    else:
        raise RuntimeError(
            f"No tree-sitter grammar found for '{lang}' "
            f"(tried: {names}). Error: {last_err}"
        )

    try:
        from tree_sitter_language_pack import get_parser
        parser = get_parser(name)
    except (ImportError, AttributeError):
        from tree_sitter import Parser
        try:
            parser = Parser(ts_lang)
        except TypeError:
            parser = Parser()
            parser.set_language(ts_lang)

    _parser_cache[lang] = (parser, ts_lang)
    return parser, ts_lang


def detect_language(file_path, all_files):
    """Detect language from file extension, with .h disambiguation."""
    ext = Path(file_path).suffix.lower()
    if ext == ".h":
        exts = {Path(f).suffix.lower() for f in all_files}
        if ".m" in exts or ".mm" in exts:
            return "objc"
        if any(e in exts for e in (".cpp", ".cc", ".cxx")):
            return "cpp"
        return "c"
    return EXT_TO_LANG.get(ext)


# ─── Identifier collection ───────────────────────────────────────────────────

def collect_identifiers(node):
    """Collect all identifier-like names in a node's subtree."""
    ids = set()
    if "identifier" in node.type.lower():
        text = node.text.decode("utf-8")
        if text:
            ids.add(text)
    for child in node.children:
        ids.update(collect_identifiers(child))
    return ids


# ─── Base extractor ──────────────────────────────────────────────────────────

class BaseExtractor:
    """Shared AST walker for symbol extraction.

    Subclasses define DEFINITIONS (node_type → symbol_kind) and
    CONTAINERS (node types whose children may contain definitions).
    Override get_name/get_visibility/get_signature for language specifics.
    """

    DEFINITIONS = {}   # {node_type: symbol_kind}
    CONTAINERS = set() # node types to recurse into for nested defs

    def extract(self, root, source, file_path):
        """Walk AST root and return list of raw symbol dicts."""
        return self._walk(root, source, file_path, prefix="")

    def _walk(self, node, source, file_path, prefix):
        symbols = []
        for child in node.children:
            # Unwrap wrappers (export statements, decorators, etc.)
            unwrapped = self.unwrap(child)

            target = unwrapped if unwrapped else child
            if target.type in self.DEFINITIONS:
                sym = self._extract_one(target, source, file_path, prefix)
                if sym:
                    symbols.append(sym)
                    # If this definition is also a container, recurse
                    if target.type in self.CONTAINERS:
                        symbols.extend(
                            self._walk(target, source, file_path, sym["name"])
                        )
                continue

            # Recurse into pure containers (impl blocks, class bodies, etc.)
            if child.type in self.CONTAINERS:
                cname = self.get_container_name(child) or prefix
                symbols.extend(self._walk(child, source, file_path, cname))
        return symbols

    def _extract_one(self, node, source, file_path, prefix):
        name = self.get_name(node)
        if not name:
            return None
        kind = self.DEFINITIONS[node.type]
        if callable(kind):
            kind = kind(node, source)
            if not kind:
                return None
        full_name = f"{prefix}.{name}" if prefix else name
        return {
            "name": full_name,
            "kind": kind,
            "visibility": self.get_visibility(node, source),
            "file": file_path,
            "line": node.start_point[0] + 1,
            "signature": self.get_signature(node, source),
            "_node": node,
        }

    def get_name(self, node):
        """Extract symbol name. Default: look for 'name' field."""
        name_node = node.child_by_field_name("name")
        if name_node:
            return name_node.text.decode("utf-8")
        return None

    def get_visibility(self, node, source):
        return "pub"

    def get_signature(self, node, source):
        return None

    def get_container_name(self, node):
        return self.get_name(node)

    def unwrap(self, node):
        """Unwrap wrapper nodes. Return inner definition node or None."""
        return None


# ─── Language extractors ──────────────────────────────────────────────────────

class ZigExtractor(BaseExtractor):
    # Zig's tree-sitter grammar uses PascalCase node types.
    # AST: source_file > [pub, Decl > [FnProto/VarDecl > [IDENTIFIER, ...]]]
    # `Decl` is a wrapper — we recurse into it via CONTAINERS.
    DEFINITIONS = {
        "FnProto": "function",
        "VarDecl": "constant",  # refined to struct/enum in _zig_kind()
    }
    CONTAINERS = {"Decl", "TopLevelDecl", "ContainerDecl"}

    def _zig_kind(self, node, source):
        """Refine VarDecl kind: if value is a ContainerDecl, use struct/enum/union."""
        if node.type != "VarDecl":
            return None
        # Walk children looking for ContainerDecl
        for child in node.children:
            if child.type == "ContainerDecl":
                # Check the container keyword (struct, enum, union)
                for gc in child.children:
                    text = gc.text.decode("utf-8") if gc.text else ""
                    if text == "struct":
                        return "struct"
                    if text == "enum":
                        return "enum"
                    if text == "union":
                        return "union"
                return "struct"  # default container
            # ContainerDecl may be nested inside ErrorUnionExpr > SuffixExpr
            if child.type in ("ErrorUnionExpr", "SuffixExpr"):
                for gc in child.children:
                    if gc.type == "ContainerDecl":
                        return self._container_keyword(gc)
                    if gc.type == "SuffixExpr":
                        for ggc in gc.children:
                            if ggc.type == "ContainerDecl":
                                return self._container_keyword(ggc)
        return "constant"

    def _container_keyword(self, container_node):
        for child in container_node.children:
            text = child.text.decode("utf-8") if child.text else ""
            if text in ("struct", "enum", "union"):
                return text
        return "struct"

    def extract(self, root, source, file_path):
        symbols = self._walk(root, source, file_path, prefix="")
        # Refine VarDecl kinds and filter out @import bindings
        filtered = []
        for sym in symbols:
            node = sym.get("_node")
            if node and node.type == "VarDecl":
                # Skip @import bindings (e.g., const std = @import("std"))
                node_text = node.text.decode("utf-8", errors="replace")
                if "@import" in node_text:
                    continue
                refined = self._zig_kind(node, source)
                if refined:
                    sym["kind"] = refined
            filtered.append(sym)
        return filtered

    def get_name(self, node):
        # Zig uses IDENTIFIER children (PascalCase)
        for child in node.children:
            if child.type == "IDENTIFIER":
                return child.text.decode("utf-8")
        # Also try field-based access as fallback
        name = super().get_name(node)
        if name:
            return name
        return None

    def get_visibility(self, node, source):
        # In Zig, `pub` is a sibling BEFORE the `Decl` wrapper, not a child
        # of FnProto/VarDecl. Check parent's preceding siblings.
        parent = node.parent
        if parent and parent.type == "Decl":
            # Check siblings of Decl (children of Decl's parent)
            grandparent = parent.parent
            if grandparent:
                found_pub = False
                for sibling in grandparent.children:
                    if sibling is parent:
                        break
                    if sibling.type == "pub" or sibling.text == b"pub":
                        found_pub = True
                if found_pub:
                    return "pub"
        # Also check within the Decl wrapper itself
        if parent and parent.type == "Decl":
            for child in parent.children:
                if child.type == "pub" or child.text == b"pub":
                    return "pub"
        # Fallback: check source text on the line before the definition
        line_start = source[: node.start_byte].rfind(b"\n") + 1
        prefix = source[line_start : node.start_byte].strip()
        if prefix.startswith(b"pub") or prefix == b"pub":
            return "pub"
        return "private"

    def get_signature(self, node, source):
        if node.type != "FnProto":
            return None
        body = node.child_by_field_name("body")
        if body:
            sig = source[node.start_byte : body.start_byte].decode("utf-8").strip()
        else:
            sig = node.text.decode("utf-8").strip()
        # Strip 'fn name' prefix, keep from '(' onward
        paren = sig.find("(")
        if paren >= 0:
            return sig[paren:].strip()
        return None


class PythonExtractor(BaseExtractor):
    DEFINITIONS = {
        "function_definition": "function",
        "class_definition": "class",
    }
    CONTAINERS = {"class_definition", "class_body"}

    def get_visibility(self, node, source):
        name = self.get_name(node)
        if name and name.startswith("_") and not name.startswith("__"):
            return "private"
        return "pub"

    def get_signature(self, node, source):
        if node.type != "function_definition":
            return None
        params = node.child_by_field_name("parameters")
        ret = node.child_by_field_name("return_type")
        if params:
            sig = params.text.decode("utf-8")
            if ret:
                sig += " -> " + ret.text.decode("utf-8")
            return sig
        return None

    def unwrap(self, node):
        if node.type == "decorated_definition":
            defn = node.child_by_field_name("definition")
            return defn if defn else None
        return None


class GoExtractor(BaseExtractor):
    DEFINITIONS = {
        "function_declaration": "function",
        "method_declaration": "method",
    }
    CONTAINERS = {"type_declaration"}

    def extract(self, root, source, file_path):
        symbols = super().extract(root, source, file_path)
        # Also extract type specs from type declarations
        symbols.extend(self._extract_type_specs(root, source, file_path))
        # Also extract top-level const/var
        symbols.extend(self._extract_const_var(root, source, file_path))
        return symbols

    def _extract_type_specs(self, node, source, file_path):
        symbols = []
        for child in node.children:
            if child.type == "type_declaration":
                for spec in child.children:
                    if spec.type == "type_spec":
                        name_node = spec.child_by_field_name("name")
                        type_node = spec.child_by_field_name("type")
                        if name_node:
                            name = name_node.text.decode("utf-8")
                            kind = "type_alias"
                            if type_node:
                                if type_node.type == "struct_type":
                                    kind = "struct"
                                elif type_node.type == "interface_type":
                                    kind = "interface"
                            vis = "pub" if name[0].isupper() else "private"
                            symbols.append({
                                "name": name,
                                "kind": kind,
                                "visibility": vis,
                                "file": file_path,
                                "line": spec.start_point[0] + 1,
                                "signature": None,
                                "_node": spec,
                            })
            # Only recurse into package-level nodes, not function bodies
            elif child.type in ("source_file",):
                symbols.extend(self._extract_type_specs(child, source, file_path))
        return symbols

    def _extract_const_var(self, node, source, file_path):
        symbols = []
        for child in node.children:
            if child.type in ("const_declaration", "var_declaration"):
                kind = "constant" if child.type == "const_declaration" else "variable"
                for spec in child.children:
                    if spec.type in ("const_spec", "var_spec"):
                        name_node = spec.child_by_field_name("name")
                        if name_node:
                            name = name_node.text.decode("utf-8")
                            vis = "pub" if name[0].isupper() else "private"
                            symbols.append({
                                "name": name,
                                "kind": kind,
                                "visibility": vis,
                                "file": file_path,
                                "line": spec.start_point[0] + 1,
                                "signature": None,
                                "_node": spec,
                            })
        return symbols

    def get_visibility(self, node, source):
        name = self.get_name(node)
        if name and name[0].isupper():
            return "pub"
        return "private"

    def get_signature(self, node, source):
        if node.type not in ("function_declaration", "method_declaration"):
            return None
        params = node.child_by_field_name("parameters")
        result = node.child_by_field_name("result")
        if params:
            sig = params.text.decode("utf-8")
            if result:
                sig += " " + result.text.decode("utf-8")
            return sig
        return None


class RustExtractor(BaseExtractor):
    DEFINITIONS = {
        "function_item": "function",
        "struct_item": "struct",
        "enum_item": "enum",
        "trait_item": "trait",
        "type_item": "type_alias",
        "const_item": "constant",
        "static_item": "variable",
    }
    CONTAINERS = {"impl_item", "trait_item"}

    def get_visibility(self, node, source):
        for child in node.children:
            if child.type == "visibility_modifier":
                return "pub"
        return "private"

    def get_container_name(self, node):
        if node.type == "impl_item":
            type_node = node.child_by_field_name("type")
            if type_node:
                return type_node.text.decode("utf-8")
        return super().get_container_name(node)

    def get_signature(self, node, source):
        if node.type != "function_item":
            return None
        params = node.child_by_field_name("parameters")
        ret = node.child_by_field_name("return_type")
        if params:
            sig = params.text.decode("utf-8")
            if ret:
                sig += " -> " + ret.text.decode("utf-8")
            return sig
        return None


class JavaExtractor(BaseExtractor):
    DEFINITIONS = {
        "class_declaration": "class",
        "method_declaration": "method",
        "interface_declaration": "interface",
        "enum_declaration": "enum",
        "constructor_declaration": "method",
    }
    CONTAINERS = {
        "class_declaration", "interface_declaration", "enum_declaration",
        "class_body", "interface_body", "enum_body",
    }

    def get_visibility(self, node, source):
        for child in node.children:
            if child.type == "modifiers":
                text = child.text.decode("utf-8")
                if "public" in text:
                    return "pub"
                if "private" in text:
                    return "private"
                if "protected" in text:
                    return "protected"
        return "package"

    def get_signature(self, node, source):
        if node.type not in ("method_declaration", "constructor_declaration"):
            return None
        params = node.child_by_field_name("parameters")
        ret_type = node.child_by_field_name("type")
        if params:
            sig = params.text.decode("utf-8")
            if ret_type:
                sig = ret_type.text.decode("utf-8") + " " + sig
            return sig
        return None


class KotlinExtractor(BaseExtractor):
    DEFINITIONS = {
        "function_declaration": "function",
        "class_declaration": "class",
        "object_declaration": "class",
        "property_declaration": "variable",
    }
    CONTAINERS = {"class_declaration", "class_body", "object_declaration"}

    def get_name(self, node):
        name = super().get_name(node)
        if name:
            return name
        # Kotlin may use simple_identifier
        for child in node.children:
            if child.type in ("simple_identifier", "identifier"):
                return child.text.decode("utf-8")
        return None

    def get_visibility(self, node, source):
        for child in node.children:
            if child.type == "modifiers":
                text = child.text.decode("utf-8")
                if "private" in text:
                    return "private"
                if "internal" in text:
                    return "internal"
                if "protected" in text:
                    return "protected"
        return "pub"


class TypeScriptExtractor(BaseExtractor):
    DEFINITIONS = {
        "function_declaration": "function",
        "class_declaration": "class",
        "interface_declaration": "interface",
        "type_alias_declaration": "type_alias",
        "enum_declaration": "enum",
        "method_definition": "method",
    }
    CONTAINERS = {"class_declaration", "class_body"}

    def get_visibility(self, node, source):
        # Check if wrapped in export_statement
        parent = node.parent
        if parent and parent.type == "export_statement":
            return "pub"
        # Check for export keyword in lexical_declaration wrapper
        return "private"

    def get_signature(self, node, source):
        if node.type not in ("function_declaration", "method_definition"):
            return None
        params = node.child_by_field_name("parameters")
        ret = node.child_by_field_name("return_type")
        if params:
            sig = params.text.decode("utf-8")
            if ret:
                sig += ": " + ret.text.decode("utf-8")
            return sig
        return None

    def unwrap(self, node):
        if node.type == "export_statement":
            decl = node.child_by_field_name("declaration")
            if decl:
                return decl
            # Check children for declaration
            for child in node.children:
                if child.type in self.DEFINITIONS:
                    return child
        return None

    def extract(self, root, source, file_path):
        symbols = super().extract(root, source, file_path)
        symbols.extend(self._extract_lexical_defs(root, source, file_path))
        return symbols

    def _extract_lexical_defs(self, node, source, file_path):
        """Extract const/let declarations with arrow functions or classes."""
        symbols = []
        for child in node.children:
            target = child
            is_exported = False
            if child.type == "export_statement":
                is_exported = True
                decl = child.child_by_field_name("declaration")
                if decl:
                    target = decl
                else:
                    continue

            if target.type in ("lexical_declaration", "variable_declaration"):
                for declarator in target.children:
                    if declarator.type == "variable_declarator":
                        name_node = declarator.child_by_field_name("name")
                        value_node = declarator.child_by_field_name("value")
                        if name_node and value_node:
                            name = name_node.text.decode("utf-8")
                            kind = "variable"
                            if value_node.type in ("arrow_function", "function"):
                                kind = "function"
                            elif value_node.type in ("class", "class_expression"):
                                kind = "class"
                            symbols.append({
                                "name": name,
                                "kind": kind,
                                "visibility": "pub" if is_exported else "private",
                                "file": file_path,
                                "line": declarator.start_point[0] + 1,
                                "signature": None,
                                "_node": declarator,
                            })
        return symbols


class JavaScriptExtractor(TypeScriptExtractor):
    """JavaScript shares most extraction logic with TypeScript."""
    DEFINITIONS = {
        "function_declaration": "function",
        "class_declaration": "class",
        "method_definition": "method",
    }


class CExtractor(BaseExtractor):
    DEFINITIONS = {
        "function_definition": "function",
        "type_definition": "type_alias",
    }
    # Preprocessor blocks and linkage specs act as containers —
    # headers wrap everything in #ifdef guards and extern "C" blocks
    CONTAINERS = {
        "preproc_ifdef", "preproc_if", "preproc_ifndef",
        "preproc_else", "preproc_elif",
        "linkage_specification", "declaration_list",
    }

    def extract(self, root, source, file_path):
        symbols = super().extract(root, source, file_path)
        symbols.extend(self._extract_named_types(root, source, file_path))
        return symbols

    def _extract_named_types(self, node, source, file_path):
        """Extract named struct/enum specifiers and function prototypes from declarations.

        Recurses into preprocessor wrappers (preproc_ifdef, preproc_if, etc.)
        since header files wrap everything in include guards.
        """
        symbols = []
        for child in node.children:
            if child.type == "declaration":
                # Check for function prototypes (declarations with function_declarator)
                proto_name = self._find_function_declarator_name(child)
                if proto_name:
                    symbols.append({
                        "name": proto_name,
                        "kind": "function",
                        "visibility": self.get_visibility(child, source),
                        "file": file_path,
                        "line": child.start_point[0] + 1,
                        "signature": child.text.decode("utf-8").rstrip(";").strip(),
                        "_node": child,
                    })
                # Check for struct/enum/union specifiers
                for sub in child.children:
                    sym = self._check_specifier(sub, source, file_path)
                    if sym:
                        symbols.append(sym)
            elif child.type == "type_definition":
                for sub in child.children:
                    sym = self._check_specifier(sub, source, file_path)
                    if sym:
                        symbols.append(sym)
            elif child.type.startswith("preproc_"):
                # Recurse into preprocessor blocks (#ifdef, #if, #ifndef, etc.)
                symbols.extend(self._extract_named_types(child, source, file_path))
        return symbols

    def _find_function_declarator_name(self, node):
        """Recursively find a function_declarator in a declaration's children."""
        for child in node.children:
            if child.type == "function_declarator":
                return self._declarator_name(child)
            # Traverse through pointer_declarator, parenthesized_declarator, etc.
            if "declarator" in child.type:
                result = self._find_function_declarator_name(child)
                if result:
                    return result
        return None

    def _check_specifier(self, node, source, file_path):
        if node.type in ("struct_specifier", "enum_specifier", "union_specifier"):
            name_node = node.child_by_field_name("name")
            if name_node:
                kind_map = {
                    "struct_specifier": "struct",
                    "enum_specifier": "enum",
                    "union_specifier": "union",
                }
                return {
                    "name": name_node.text.decode("utf-8"),
                    "kind": kind_map[node.type],
                    "visibility": "pub",
                    "file": file_path,
                    "line": node.start_point[0] + 1,
                    "signature": None,
                    "_node": node,
                }
        return None

    def get_container_name(self, node):
        # Preprocessor blocks and linkage specs are transparent — don't prefix symbols
        if node.type.startswith("preproc_") or node.type in ("linkage_specification", "declaration_list"):
            return ""
        return super().get_container_name(node)

    def get_name(self, node):
        if node.type == "function_definition":
            return self._declarator_name(node.child_by_field_name("declarator"))
        if node.type == "type_definition":
            declarator = node.child_by_field_name("declarator")
            if declarator:
                return self._declarator_name(declarator)
        return super().get_name(node)

    def _declarator_name(self, node):
        """Traverse C declarator chain to find the identifier."""
        if node is None:
            return None
        if node.type in ("identifier", "type_identifier"):
            return node.text.decode("utf-8")
        # Check 'declarator' field (function_declarator, pointer_declarator, etc.)
        inner = node.child_by_field_name("declarator")
        if inner:
            return self._declarator_name(inner)
        # Fallback: find first identifier child
        for child in node.children:
            if child.type in ("identifier", "type_identifier"):
                return child.text.decode("utf-8")
        return None

    def get_visibility(self, node, source):
        # static = file-scoped = private
        for child in node.children:
            if child.type == "storage_class_specifier":
                if child.text.decode("utf-8") == "static":
                    return "private"
        return "pub"

    def get_signature(self, node, source):
        if node.type != "function_definition":
            return None
        body = node.child_by_field_name("body")
        if body:
            sig = source[node.start_byte : body.start_byte].decode("utf-8").strip()
            return sig
        return None


class CppExtractor(CExtractor):
    """C++ extends C with class_specifier and access specifiers."""
    DEFINITIONS = {
        "function_definition": "function",
        "type_definition": "type_alias",
    }
    CONTAINERS = {"class_specifier", "struct_specifier"}

    def _extract_named_types(self, node, source, file_path):
        symbols = super()._extract_named_types(node, source, file_path)
        # Also extract class specifiers
        for child in node.children:
            if child.type in ("declaration", "type_definition"):
                for sub in child.children:
                    if sub.type == "class_specifier":
                        name_node = sub.child_by_field_name("name")
                        if name_node:
                            symbols.append({
                                "name": name_node.text.decode("utf-8"),
                                "kind": "class",
                                "visibility": "pub",
                                "file": file_path,
                                "line": sub.start_point[0] + 1,
                                "signature": None,
                                "_node": sub,
                            })
        return symbols


class SwiftExtractor(BaseExtractor):
    DEFINITIONS = {
        "function_declaration": "function",
        "class_declaration": "class",
        "struct_declaration": "struct",
        "enum_declaration": "enum",
        "protocol_declaration": "protocol",
        "typealias_declaration": "type_alias",
    }
    CONTAINERS = {
        "class_declaration", "struct_declaration", "enum_declaration",
        "class_body", "struct_body", "enum_body",
    }

    def get_visibility(self, node, source):
        for child in node.children:
            text = child.text.decode("utf-8") if child.text else ""
            if text in ("public", "open"):
                return "pub"
            if text in ("private", "fileprivate"):
                return "private"
            if text == "internal":
                return "internal"
            if child.type == "modifiers":
                if "public" in text or "open" in text:
                    return "pub"
                if "private" in text or "fileprivate" in text:
                    return "private"
        return "internal"

    def get_signature(self, node, source):
        if node.type != "function_declaration":
            return None
        body = node.child_by_field_name("body")
        if body:
            sig = source[node.start_byte : body.start_byte].decode("utf-8").strip()
            # Strip 'func' keyword and name, keep from '('
            paren = sig.find("(")
            if paren >= 0:
                return sig[paren:]
        return None


class ObjCExtractor(CExtractor):
    """ObjC is a superset of C — inherit C extraction and add ObjC constructs.

    This means .h files classified as 'objc' still get their C typedefs,
    structs, and function definitions extracted correctly.
    """
    DEFINITIONS = {
        # C definitions (inherited logic handles these)
        "function_definition": "function",
        "type_definition": "type_alias",
        # ObjC-specific definitions
        "class_interface": "class",
        # class_implementation is a CONTAINER only — not a definition,
        # to avoid duplicate class entries (interface already defines the class)
        "protocol_declaration": "protocol",
        "method_declaration": "method",
        "method_definition": "method",
    }
    CONTAINERS = {
        # Only recurse into implementation (has method bodies), not interface
        # (has only declarations) — avoids duplicate methods
        "class_implementation", "category_interface",
        "implementation_definition",
        # Inherit C preprocessor and linkage containers
        "preproc_ifdef", "preproc_if", "preproc_ifndef",
        "preproc_else", "preproc_elif",
        "linkage_specification", "declaration_list",
    }

    def get_name(self, node):
        # For C-style nodes, use C's name extraction
        if node.type in ("function_definition", "type_definition"):
            return CExtractor.get_name(self, node)
        name = super(CExtractor, self).get_name(node)
        if name:
            return name
        # ObjC method declarations/definitions have selector-based names
        if node.type in ("method_declaration", "method_definition"):
            selector_parts = []
            for child in node.children:
                if child.type in ("selector", "keyword_selector"):
                    return child.text.decode("utf-8").rstrip(":")
                if child.type == "keyword_declarator":
                    kw = child.child_by_field_name("keyword")
                    if kw:
                        selector_parts.append(kw.text.decode("utf-8"))
            if selector_parts:
                return ":".join(selector_parts)
        # For class_interface/class_implementation, look for class name
        for child in node.children:
            if child.type in ("identifier", "type_identifier"):
                return child.text.decode("utf-8")
        return None

    def get_visibility(self, node, source):
        if node.type in ("class_interface", "protocol_declaration"):
            return "pub"
        if node.type in ("function_definition", "type_definition"):
            return CExtractor.get_visibility(self, node, source)
        return "pub"


# ─── Extractor registry ──────────────────────────────────────────────────────

EXTRACTORS = {
    "zig": ZigExtractor(),
    "python": PythonExtractor(),
    "go": GoExtractor(),
    "rust": RustExtractor(),
    "java": JavaExtractor(),
    "kotlin": KotlinExtractor(),
    "typescript": TypeScriptExtractor(),
    "javascript": JavaScriptExtractor(),
    "c": CExtractor(),
    "cpp": CppExtractor(),
    "swift": SwiftExtractor(),
    "objc": ObjCExtractor(),
}


# ─── Dependency resolution ───────────────────────────────────────────────────

def resolve_dependencies(symbols):
    """For each symbol, find which other inventory symbols it references."""
    all_names = {s["name"].split(".")[-1] for s in symbols.values()}
    full_names = set(symbols.keys())

    for sym_name, sym in symbols.items():
        node = sym.get("_node")
        if not node:
            sym["depends_on"] = []
            continue

        # Collect all identifiers in this symbol's subtree
        refs = collect_identifiers(node)

        # Filter: keep only references to other inventory symbols
        base_name = sym_name.split(".")[-1]
        deps = set()
        for ref in refs:
            if ref == base_name:
                continue  # Skip self-reference
            # Check against full qualified names and base names
            if ref in full_names:
                deps.add(ref)
            else:
                # Check if ref matches any symbol's base name
                for other_name in full_names:
                    other_base = other_name.split(".")[-1]
                    if ref == other_base and other_name != sym_name:
                        deps.add(other_name)
                        break

        sym["depends_on"] = sorted(deps)


# ─── Inventory builder ───────────────────────────────────────────────────────

def build_inventory(root, files, debug=False):
    """Parse all files and build the complete symbol inventory."""
    root = Path(root).resolve()
    symbols = {}
    languages_seen = set()

    for file_path in files:
        abs_path = (root / file_path).resolve()
        rel_path = str(Path(file_path))

        lang = detect_language(rel_path, files)
        if not lang:
            print(f"WARNING: Unknown language for {rel_path}, skipping.", file=sys.stderr)
            continue

        languages_seen.add(lang)

        if lang not in EXTRACTORS:
            print(f"WARNING: No extractor for language '{lang}', skipping {rel_path}.", file=sys.stderr)
            continue

        try:
            source = abs_path.read_bytes()
        except FileNotFoundError:
            print(f"WARNING: File not found: {abs_path}, skipping.", file=sys.stderr)
            continue

        parser, _ = make_parser(lang)
        tree = parser.parse(source)

        if debug:
            print(f"\n=== AST for {rel_path} ({lang}) ===", file=sys.stderr)
            _print_tree(tree.root_node, depth=0, max_depth=4)

        extractor = EXTRACTORS[lang]
        raw_symbols = extractor.extract(tree.root_node, source, rel_path)

        if not raw_symbols:
            print(
                f"WARNING: No symbols found in {rel_path} ({lang}). "
                f"Run with --debug to inspect the AST.",
                file=sys.stderr,
            )

        for sym in raw_symbols:
            name = sym["name"]
            # Handle name collisions by qualifying with file stem
            if name in symbols:
                existing = symbols[name]
                # Only re-key the existing entry if it hasn't been qualified yet
                if "." not in name or existing["file"] != rel_path:
                    existing_qual = f"{Path(existing['file']).stem}.{name}"
                    if existing_qual != name:
                        symbols.pop(name)
                        # Avoid overwriting an already-qualified entry
                        while existing_qual in symbols:
                            existing_qual = f"{existing['file'].replace('/', '.')}.{name}"
                        symbols[existing_qual] = existing
                        existing["name"] = existing_qual
                name = f"{Path(rel_path).stem}.{name}"
                # Ensure uniqueness for the new entry too
                while name in symbols:
                    name = f"{rel_path.replace('/', '.')}.{sym['name']}"
                sym["name"] = name
            symbols[name] = sym

    # Second pass: resolve dependencies
    resolve_dependencies(symbols)

    # Remove internal _node references before output
    for sym in symbols.values():
        sym.pop("_node", None)
        # Remove None signatures
        if sym.get("signature") is None:
            del sym["signature"]

    return {
        "symbols": symbols,
        "metadata": {
            "extracted_at": datetime.now(timezone.utc).isoformat(),
            "files_analyzed": sorted(files),
            "languages": sorted(languages_seen),
            "tool_version": TOOL_VERSION,
        },
    }


def _print_tree(node, depth=0, max_depth=5):
    """Debug helper: print AST structure."""
    if depth > max_depth:
        return
    indent = "  " * depth
    text_preview = ""
    if node.child_count == 0:
        text = node.text.decode("utf-8", errors="replace")
        if len(text) <= 40:
            text_preview = f" = {text!r}"
    print(f"{indent}{node.type}{text_preview}", file=sys.stderr)
    for child in node.children:
        _print_tree(child, depth + 1, max_depth)


# ─── CLI ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Extract symbol inventory from source files using tree-sitter."
    )
    parser.add_argument(
        "--root", required=True,
        help="Project root directory",
    )
    parser.add_argument(
        "--files", required=True, nargs="+",
        help="Source files to analyze (relative to root)",
    )
    parser.add_argument(
        "--output", required=True,
        help="Output path for reference-inventory.json",
    )
    parser.add_argument(
        "--debug", action="store_true",
        help="Print AST structure for each file (for troubleshooting)",
    )

    args = parser.parse_args()

    # Verify tree-sitter is available
    try:
        import tree_sitter_language_pack  # noqa: F401
    except ImportError:
        print(
            "ERROR: tree-sitter-language-pack is not installed.\n"
            "Run: pip install tree-sitter tree-sitter-language-pack",
            file=sys.stderr,
        )
        sys.exit(1)

    inventory = build_inventory(args.root, args.files, debug=args.debug)

    # Write output
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(inventory, f, indent=2)

    symbol_count = len(inventory["symbols"])
    file_count = len(inventory["metadata"]["files_analyzed"])
    print(f"Extracted {symbol_count} symbols from {file_count} files → {args.output}")


if __name__ == "__main__":
    main()
