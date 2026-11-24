#!/usr/bin/env python3
"""Trusted installer for the project symbol index.

  install.py core --env DIR              private virtual environment with pinned runtime
  install.py language LANG --env DIR     one pinned grammar into DIR/grammars/LANG

Only requirements from requirements.lock are installed, always with
--require-hashes and --no-deps.  A grammar is installed into a temporary
directory, validated by the parser, then swapped into place, so a failed or
cancelled installation leaves the previous grammar usable.  Extra pip options
(--find-links/--no-index for an offline wheelhouse) pass through unchanged.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORE = ("tree-sitter", "watchdog")


def lock_lines(lock):
    return {line.split("==", 1)[0]: line for line in
            (raw.strip() for raw in Path(lock).read_text().splitlines())
            if line and not line.startswith("#")}


def requirement_file(lock, names, directory):
    lines = lock_lines(lock)
    missing = [n for n in names if n not in lines]
    if missing:
        raise SystemExit(f"Not pinned in {lock}: {', '.join(missing)}")
    path = Path(directory) / "requirements.txt"
    path.write_text("".join(lines[n] + "\n" for n in names))
    return path


def pip(python, requirements, pip_args, *extra):
    subprocess.run([python, "-m", "pip", "install", "--disable-pip-version-check", "--quiet",
                    "--require-hashes", "--no-deps", "--only-binary", ":all:", "-r", str(requirements),
                    *extra, *pip_args], check=True)


def install_core(env, lock, pip_args):
    venv = Path(env) / "venv"
    python = venv / "bin" / "python3"
    if not python.exists():
        subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
    with tempfile.TemporaryDirectory() as tmp:
        pip(str(python), requirement_file(lock, CORE, tmp), pip_args)
    subprocess.run([str(python), "-I", "-c", "import sqlite3, tree_sitter, watchdog;"
                    "c = sqlite3.connect(':memory:'); c.execute('pragma journal_mode=wal')"], check=True)
    print(json.dumps({"installed": "core", "python": str(python)}))


def install_language(env, lang, registry_path, lock, pip_args):
    registry = json.loads(Path(registry_path).read_text())["languages"]
    if lang not in registry:
        raise SystemExit(f"Unsupported language: {lang}")
    python = Path(env) / "venv" / "bin" / "python3"
    if not python.exists():
        raise SystemExit("Run `install.py core' first")
    requirement = registry[lang]["grammar"]["requirement"].split("==", 1)[0]
    grammars = Path(env) / "grammars"
    grammars.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".install-{lang}-", dir=grammars))
    try:
        target = staging / "site"
        pip(str(python), requirement_file(lock, [requirement], staging), pip_args, "--target", str(target))
        (target / "INSTALLED.json").write_text(json.dumps({"requirement": registry[lang]["grammar"]["requirement"]}))
        subprocess.run([str(python), "-I", str(HERE / "parsers.py"), "--validate", lang,
                        "--registry", str(registry_path), "--grammar-dir", str(target)], check=True)
        final, old = grammars / lang, grammars / f".old-{lang}"
        shutil.rmtree(old, ignore_errors=True)
        if final.exists():
            final.rename(old)
        target.rename(final)
        shutil.rmtree(old, ignore_errors=True)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    print(json.dumps({"installed": lang}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("what", choices=["core", "language"])
    parser.add_argument("lang", nargs="?")
    parser.add_argument("--env", required=True)
    parser.add_argument("--registry", default=str(HERE / "languages.json"))
    parser.add_argument("--lock", default=str(HERE / "requirements.lock"))
    args, pip_args = parser.parse_known_args()
    if args.what == "core":
        install_core(args.env, args.lock, pip_args)
    else:
        install_language(args.env, args.lang, args.registry, args.lock, pip_args)


if __name__ == "__main__":
    main()
