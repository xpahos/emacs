#!/usr/bin/env python3
"""Infer local Protobuf import roots, then replace this process with Buf LSP.

Scanning happens outside Emacs. No build scripts are read or executed, and no
configuration or cache files are written to the source project.
"""
import ast
from collections import defaultdict, deque
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys


TOKENS = re.compile(r'''//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[A-Za-z_]\w*|[^\s]''', re.S)
WELL_KNOWN = {
    f"google/protobuf/{name}.proto" for name in (
        "any", "api", "descriptor", "duration", "empty", "field_mask",
        "source_context", "struct", "timestamp", "type", "wrappers")
}


def imports(file):
    """Read import declarations, ignoring comments and other string literals."""
    tokens = [t for t in TOKENS.findall(file.read_text(encoding="utf-8"))
              if not t.startswith(("//", "/*"))]
    for i, token in enumerate(tokens):
        if token != "import":
            continue
        tail = tokens[i + 1:i + 4]
        if tail and tail[0] in ("public", "weak"):
            tail = tail[1:]
        if len(tail) < 2 or not tail[0].startswith(('"', "'")) or tail[1] != ";":
            continue
        name = ast.literal_eval(tail[0])
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or "\\" in name or not name.endswith(".proto"):
            raise ValueError(f"Invalid import {name!r} in {file}")
        yield name


def proto_files(root):
    """Include ignored/vendor files; do not follow directory symlinks or VCS data."""
    def walk_error(error):
        raise error

    for directory, dirs, files in os.walk(root, onerror=walk_error):
        dirs[:] = sorted(d for d in dirs if d not in {".git", ".arc", ".hg", ".svn"})
        for name in sorted(files):
            if name.endswith(".proto"):
                file = Path(directory) / name
                if file.resolve().is_relative_to(root):
                    yield file


def resolve_import(name, importer, root, by_name):
    """Prefer an ancestor include path, then the closest unambiguous file."""
    candidates = [p for p in by_name.get(PurePosixPath(name).name, [])
                  if p.as_posix().endswith("/" + name)]
    for directory in (importer.parent, *importer.parent.parents):
        if not directory.is_relative_to(root):
            break
        if directory / name in candidates:
            return directory / name
    if not candidates:
        return None  # Buf supplies diagnostics for dependencies absent from disk.
    proximity = {p: len(Path(os.path.commonpath((importer.parent, p.parent))).parts)
                 for p in candidates}
    candidates = sorted(p for p in candidates if proximity[p] == max(proximity.values()))
    if len(candidates) > 1:
        contents = candidates[0].read_bytes()
        # Equal text can still resolve imports to different versions nearby.
        if (any(p.read_bytes() != contents for p in candidates[1:])
                or any(name not in WELL_KNOWN for name in imports(candidates[0]))):
            choices = ", ".join(str(p.relative_to(root)) for p in candidates)
            raise ValueError(f"Ambiguous import {name!r} in {importer.relative_to(root)}: {choices}")
    return candidates[0]


def configuration(root, entry):
    """Infer roots from a directory's schemas and their transitive imports."""
    root, entry = root.resolve(), entry.resolve()
    if not entry.is_relative_to(root):
        raise ValueError("The Protobuf file is outside its Emacs project")
    by_name = defaultdict(list)
    siblings = []
    for file in proto_files(root):
        by_name[file.name].append(file)
        if file.parent == entry.parent:
            siblings.append(file)
    queue, visited, roots = deque(siblings), set(), set()
    while queue:
        file = queue.popleft()
        if file in visited:
            continue
        visited.add(file)
        for name in imports(file):
            if name in WELL_KNOWN:
                continue
            dependency = resolve_import(name, file, root, by_name)
            if dependency is not None:
                roots.add(dependency.parents[len(PurePosixPath(name).parts) - 1])
                queue.append(dependency)
    if not any(entry.parent.is_relative_to(path) for path in roots):
        roots.add(entry.parent)
    modules = []
    for path in sorted(roots):
        module = {"path": path.relative_to(root).as_posix()}
        nested = [other.relative_to(root).as_posix() for other in sorted(roots)
                  if other != path and other.is_relative_to(path)]
        if nested:
            module["excludes"] = nested
        modules.append(module)
    return {"version": "v2", "modules": modules}


def main():
    root, entry = map(Path, sys.argv[1:])
    config = configuration(root, entry)
    os.chdir(root)
    os.execvp("buf", ["buf", "lsp", "serve", "--config", json.dumps(config)])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, SyntaxError) as error:
        print(f"Protobuf import discovery: {error}", file=sys.stderr)
        sys.exit(1)
