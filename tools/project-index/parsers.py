#!/usr/bin/env python3
"""Trusted language registry and Tree-sitter declaration extraction.

Run as `parsers.py --serve' this is the isolated parser subprocess: one JSON
job per line on stdin, one result per line on stdout.  The coordinator kills
and restarts it on timeout or crash, so a pathological file cannot take the
index down with it.
"""
import argparse
import base64
import bisect
import hashlib
import importlib
import importlib.util
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ALLOWED_PREDICATES = {"eq?", "not-eq?", "match?", "not-match?", "any-of?", "not-any-of?"}
# Declarations that give their members a qualified prefix.
CONTAINERS = {"type", "class", "struct", "interface", "enum", "trait", "union", "object",
              "module", "namespace", "message", "service", "_scope"}
PUBLIC_KINDS = {"type", "class", "struct", "interface", "enum", "trait", "union", "object",
                "module", "namespace", "package", "message", "service", "rpc", "function",
                "method", "constructor", "field", "property", "constant", "variable",
                "member", "macro", "alias"}


class AdapterError(Exception):
    """A registry entry, grammar or query that cannot be used as configured."""


def glob_regex(pattern):
    """Compile a root-relative glob: `*' and `?' stay within one path component,
    `**' spans components, and a pattern without `/' matches a basename at any depth."""
    pattern = pattern.strip().rstrip("/")
    anchored = "/" in pattern
    pattern = pattern.lstrip("/")
    out, i = [], 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
            continue
        if pattern.startswith("**", i):
            out.append(".*")
            i += 2
            continue
        out.append({"*": "[^/]*", "?": "[^/]"}.get(c, re.escape(c)))
        i += 1
    body = "".join(out)
    return re.compile(("" if anchored else "(?:.*/)?") + body + r"\Z", re.S)


def glob_any(regexes, rel):
    return any(r.match(rel) for r in regexes)


def normalize(raw, encoding="utf-8"):
    """Strictly decoded RAW as UTF-8 without a BOM and with LF line ends.
    The SHA-256 of the result is the source revision, for disk and buffers alike."""
    text = raw.decode(encoding, "strict")
    if text.startswith("\ufeff"):
        text = text[1:]
    return text.replace("\r\n", "\n").encode("utf-8")


def revision(snapshot):
    return hashlib.sha256(snapshot).hexdigest()


class Adapter:
    def __init__(self, lang, spec, query_dir):
        self.lang = lang
        self.globs = [glob_regex(g) for g in spec.get("globs", [])]
        self.shebangs = spec.get("shebangs", [])
        self.grammar = spec["grammar"]
        self.query_path = Path(query_dir) / spec["query"]
        if not self.query_path.is_file():
            raise AdapterError(f"{lang}: query {self.query_path.name} is missing")
        self.query_text = self.query_path.read_text()
        digest = hashlib.sha256(self.query_text.encode() + json.dumps(spec, sort_keys=True).encode())
        # Changes to the query or grammar pin re-extract this language's files.
        self.fingerprint = f"{lang}:{self.grammar['requirement']}:{digest.hexdigest()[:16]}"
        for predicate in re.findall(r"#([A-Za-z_-]+[?!]?)", self.query_text):
            if predicate not in ALLOWED_PREDICATES:
                raise AdapterError(f"{lang}: unsupported query directive #{predicate}")
        self._language = None
        self._query = None


class Registry:
    def __init__(self, adapters):
        self.adapters = adapters

    def detect(self, rel, first_line=b"", overrides=()):
        """The adapter for REL: user overrides first, then filename globs, then shebangs.
        Returns (adapter or None, language id or None)."""
        for regex, lang in overrides:
            if regex.match(rel):
                return self.adapters.get(lang), lang
        name = rel.rsplit("/", 1)[-1]
        best = None
        for adapter in self.adapters.values():
            for regex in adapter.globs:
                # Longer literal patterns are more specific, so `*.pb.go' beats `*.go'.
                if regex.match(name) and (best is None or len(regex.pattern) > best[0]):
                    best = (len(regex.pattern), adapter)
        if best:
            return best[1], best[1].lang
        if first_line.startswith(b"#!"):
            words = first_line[2:].decode("utf-8", "replace").split()
            program = words[1] if words and words[0].endswith("/env") and len(words) > 1 else (words[0] if words else "")
            program = program.rsplit("/", 1)[-1]
            for adapter in self.adapters.values():
                if program in adapter.shebangs:
                    return adapter, adapter.lang
        return None, None


def load_registry(path=HERE / "languages.json", query_dir=HERE / "queries"):
    data = json.loads(Path(path).read_text())
    if data.get("version") != 1:
        raise AdapterError(f"Unknown registry version in {path}")
    return Registry({lang: Adapter(lang, spec, query_dir) for lang, spec in data["languages"].items()})


def grammar_installed(adapter, grammar_root):
    return (Path(grammar_root) / adapter.lang / "INSTALLED.json").is_file()


def load_language(adapter, site):
    """The tree_sitter.Language of ADAPTER from its private grammar directory SITE."""
    import tree_sitter
    site = Path(site)
    if not (site / "INSTALLED.json").is_file():
        raise FileNotFoundError(f"Parser not installed: {adapter.lang}")
    installed = json.loads((site / "INSTALLED.json").read_text())["requirement"]
    if installed != adapter.grammar["requirement"]:
        raise AdapterError(f"{adapter.lang}: installed {installed}, registry pins {adapter.grammar['requirement']}")
    if "file" in adapter.grammar:
        # Load just this binding, not the bundle's package with its other imports.
        spec = importlib.util.spec_from_file_location(adapter.grammar["module"], site / adapter.grammar["file"])
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    else:
        if str(site) not in sys.path:
            sys.path.insert(0, str(site))
        module = importlib.import_module(adapter.grammar["module"])
    language = tree_sitter.Language(module.language())
    if not tree_sitter.MIN_COMPATIBLE_LANGUAGE_VERSION <= language.abi_version <= tree_sitter.LANGUAGE_VERSION:
        raise AdapterError(f"{adapter.lang}: grammar ABI {language.abi_version} is not supported by this runtime")
    return language


def prepare(adapter, site):
    import tree_sitter
    if adapter._query is None:
        adapter._language = load_language(adapter, site)
        try:
            adapter._query = tree_sitter.Query(adapter._language, adapter.query_text)
        except Exception as err:  # Query syntax or unknown node types
            raise AdapterError(f"{adapter.lang}: invalid declaration query: {err}") from err
        names = {adapter._query.capture_name(i) for i in range(adapter._query.capture_count)}
        if "name" not in names or not any(n.startswith("definition.") for n in names):
            raise AdapterError(f"{adapter.lang}: query needs @name and @definition.<kind> captures")
    return adapter._language, adapter._query


def _anchor(snapshot, def_start, name_end):
    """Digest of the declaration's head: its text up to the end of the name's line
    or the first brace, so overloads with different parameters differ."""
    tail = snapshot[name_end:name_end + 240]
    stop = min([i for i in (tail.find(b"\n"), tail.find(b"{"), tail.find(b";")) if i >= 0] or [len(tail)])
    head = b" ".join(snapshot[max(def_start, name_end - 400):name_end + stop].split())
    return hashlib.sha1(head).hexdigest()[:12]


def extract(snapshot, adapter, site):
    """Declarations of SNAPSHOT (normalized UTF-8).
    Returns {"status": ok|partial|failed, "declarations": [...], "diagnostics": [...]}."""
    import tree_sitter
    language, query = prepare(adapter, site)
    tree = tree_sitter.Parser(language).parse(snapshot)
    found = {}
    for _, captures in tree_sitter.QueryCursor(query).matches(tree.root_node):
        defs = [(k, v) for k, v in captures.items() if k.startswith("definition.")]
        names = captures.get("name")
        if len(defs) != 1 or not names:
            continue
        kind, (node,) = defs[0][0][len("definition."):], defs[0][1][:1]
        name = names[0]
        key = (name.start_byte, name.end_byte)
        if key in found:
            continue
        scope = [n.text.decode("utf-8", "replace") for n in captures.get("scope", [])]
        found[key] = (node.start_byte, node.end_byte, kind, name, scope)
    diagnostics = []
    lines = [0] + [m.end() for m in re.finditer(b"\n", snapshot)]
    entries = sorted(found.values(), key=lambda e: (e[0], -e[1]))
    stack, out, ordinals = [], [], {}
    for start, end, kind, name, scope in entries:
        while stack and stack[-1][1] <= start:
            stack.pop()
        if not (0 <= name.start_byte < name.end_byte <= len(snapshot)):
            raise AdapterError(f"{adapter.lang}: name capture outside the snapshot")
        try:
            text = snapshot[name.start_byte:name.end_byte].decode("utf-8")
        except UnicodeDecodeError:
            diagnostics.append(f"undecodable name at byte {name.start_byte}")
            continue
        enclosing = [s[2] for s in stack]
        if kind in CONTAINERS:
            stack.append((start, end, text))
        if kind not in PUBLIC_KINDS:
            continue
        parents = enclosing + scope
        qualified = ".".join(parents + [text])
        line = bisect.bisect_right(lines, name.start_byte) - 1
        column = len(snapshot[lines[line]:name.start_byte].decode("utf-8", "replace"))
        anchor = _anchor(snapshot, start, name.end_byte)
        ordinal = ordinals.get((qualified, kind, anchor), 0)
        ordinals[(qualified, kind, anchor)] = ordinal + 1
        out.append({"name": text, "qualified_name": qualified, "kind": kind,
                    "scope": ".".join(parents), "start_byte": name.start_byte,
                    "end_byte": name.end_byte, "line": line + 1, "column": column,
                    "anchor": anchor, "ordinal": ordinal})
    status = "partial" if tree.root_node.has_error else "ok"
    if status == "partial":
        diagnostics.append("syntax errors; declarations outside them are indexed")
    return {"status": status, "declarations": out, "diagnostics": diagnostics}


def serve(registry, grammar_root):
    """Parser subprocess loop.  Results never carry source text."""
    for line in sys.stdin.buffer:
        job = json.loads(line)
        adapter = registry.adapters.get(job["lang"])
        try:
            if adapter is None:
                raise AdapterError(f"Unsupported language: {job['lang']}")
            snapshot = base64.b64decode(job["data"])
            result = extract(snapshot, adapter, Path(grammar_root) / adapter.lang)
        except FileNotFoundError as err:
            result = {"status": "missing_parser", "declarations": [], "diagnostics": [str(err)]}
        except Exception as err:  # A broken adapter must be reported, never be an empty success.
            result = {"status": "failed", "declarations": [], "diagnostics": [f"{type(err).__name__}: {err}"]}
        result["id"] = job["id"]
        sys.stdout.write(json.dumps(result) + "\n")
        sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--validate")
    parser.add_argument("--registry", default=str(HERE / "languages.json"))
    parser.add_argument("--queries", default=str(HERE / "queries"))
    parser.add_argument("--grammars", help="directory of installed grammars, one per language")
    parser.add_argument("--grammar-dir", help="with --validate: one grammar's directory")
    args = parser.parse_args()
    registry = load_registry(args.registry, args.queries)
    if args.validate:
        adapter = registry.adapters[args.validate]
        result = extract(b"", adapter, args.grammar_dir)
        assert result["status"] == "ok", result
        print(json.dumps({"valid": args.validate, "fingerprint": adapter.fingerprint}))
    elif args.serve:
        serve(registry, args.grammars)


if __name__ == "__main__":
    main()
