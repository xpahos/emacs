#!/usr/bin/env python3
"""Disposable GUI comparison; never enables completion in the user's Emacs.

Run with a NEW output directory. Generates and compiles a Go fixture, then runs
each mode in separate GUI Emacs and gopls processes (empty gopls disk cache, Go
build cache shared and primed by fixture validation):

  sync       Eglot's own CAPF + Corfu, gopls default budget (the baseline).
  lazy-cold  go-completion.el (async request, 20 ms budget, lazy candidates),
             warmup disabled: the first request hits a cold server.
  lazy       go-completion.el as configured, including warmup. The warmup
             request is timed on its own; the first row starts after it.

Rows start at a synthetic prefix edit and trigger Corfu's auto-completion path
without its idle delay. first = any candidates visible (lazy may show a
provisional cached page); fresh = a server answer for the current text is on
screen. Pages = twenty page-downs (to row 200) after fresh; lazy builds those
candidates on demand. Candidates = everything reachable from the popup,
counted afterwards (untimed). Typing opens the broad "Bench" popup, then sends
"Func199" as real key events every 30 ms while large replies arrive; key lag is
measured from each key's planned time to the end of its command. Max timer gap
is the longest interval without a 10 ms timer firing (an event-loop stall).
gopls sends ONE complete JSON message; its decoding in Emacs is not chunked.
"""
import argparse
import json
import math
import os
import platform
from pathlib import Path
import statistics
import subprocess
import tempfile


def fixture(root):
    (root / "catalog").mkdir(parents=True)
    (root / "go.mod").write_text("module example.test/completionbench\n\ngo 1.23\n")
    for part in range(20):
        lines = ["package catalog\n"]
        lines += [f"var BenchVar{i:04d} = {i}\n" for i in range(part * 50, (part + 1) * 50)]
        lines += [f"func BenchFunc{i:05d}() int {{ return {i} }}\n"
                  for i in range(part * 1000, (part + 1) * 1000)]
        (root / "catalog" / f"symbols{part:02d}.go").write_text("".join(lines))
    (root / "catalog" / "probe.go").write_text(
        "package catalog\nconst BenchConst = 42\ntype Thing struct {\n"
        + "".join(f"Field{i:03d} int\n" for i in range(100)) + "}\n"
        + "".join(f"func (Thing) Method{i:03d}() {{}}\n" for i in range(100))
        + "func Probe() {\nBenchLocal := 1\nobj := Thing{}\n_ = BenchLocal\n_ = obj\n// BENCH\n}\n")
    (root / "probe.go").write_text(
        'package completionbench\nimport "example.test/completionbench/catalog"\n'
        'var _ = catalog.BenchVar0000\nfunc Probe() {\n// BENCH\n}\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--emacs", default="/Applications/MacPorts/Emacs.app/Contents/MacOS/Emacs")
    parser.add_argument("--go", default="/usr/local/go/bin/go")
    parser.add_argument("--gopls", default=str(Path.home() / "go/bin/gopls"))
    args = parser.parse_args()
    out = (args.output or Path(tempfile.mkdtemp(prefix="completion-bench-"))).resolve()
    out.mkdir(parents=True, exist_ok=True)
    root = out / "fixture"
    fixture(root)
    env = os.environ.copy()
    env["PATH"] = f"{Path(args.go).parent}:{Path(args.gopls).parent}:" + env["PATH"]
    env["GOTOOLCHAIN"] = "local"
    env["GOCACHE"] = str(out / "go-build-cache")
    env["GOMODCACHE"] = str(out / "go-mod-cache")
    subprocess.run([args.go, "test", "./..."], cwd=root, env=env, check=True)
    metadata = {"go": subprocess.check_output([args.go, "version"], text=True).strip(),
                "gopls": subprocess.check_output([args.gopls, "version"], text=True).strip(),
                "emacs": subprocess.check_output([args.emacs, "-Q", "--batch", "--eval",
                                                   "(princ emacs-version)"], text=True).strip(),
                "platform": platform.platform(),
                "variables": 1000, "functions": 20000, "rounds": args.rounds,
                "order": ["sync", "lazy-cold", "lazy", "lazy", "lazy-cold", "sync"]}
    (out / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    script = Path(__file__).with_suffix(".el").resolve()
    samples = []
    for number, mode in enumerate(metadata["order"]):
        run = out / f"{number}-{mode}"
        run.mkdir(exist_ok=True)
        env.update(COMPLETION_BENCH_ROOT=str(root), COMPLETION_BENCH_OUT=str(run),
                   COMPLETION_BENCH_MODE=mode, COMPLETION_BENCH_ROUNDS=str(args.rounds),
                   COMPLETION_BENCH_GOPLS=args.gopls,
                   # Each process gets a separate gopls disk cache, same Go build cache.
                   GOPLSCACHE=str(run / "gopls-cache"))
        print(f"Starting {number}: {mode}", flush=True)
        with (run / "emacs.log").open("w") as log:
            proc = subprocess.Popen([args.emacs, "-Q", "-l", str(script)], env=env,
                                    stdout=log, stderr=subprocess.STDOUT)
            try:
                status = proc.wait(timeout=600)
            except subprocess.TimeoutExpired:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                raise RuntimeError(f"Emacs timed out; see {run}") from None
        if status:
            raise RuntimeError(f"Emacs exited {status}; see {run}")
        rows = json.loads((run / "results.json").read_text())
        assert len(rows) == 1 + 14 * args.rounds, (run, len(rows))
        for row in rows:
            assert 0 <= row["first_ms"] <= row["fresh_ms"], row
            assert row["prefix"] == "BenchZZZ" or 0 < row["visible_rows"] <= 10, row
            assert row["reached_index"] == min(200, row["candidates"] - 1), row
            if row["workload"] == "typing":
                assert len(row["key_lags_ms"]) == len(row["prefix"]) - 5, row
            row.update(mode=mode, run=number)
        samples.extend(rows)
        print(f"Finished {mode}: {len(rows)} measurements", flush=True)
    (out / "results.json").write_text(json.dumps(samples, indent=2) + "\n")
    modes = ("sync", "lazy-cold", "lazy")

    def quantile(values):
        values = sorted(v for v in values if v is not None)
        if not values:
            return "—"
        return f"{statistics.median(values):.1f} / {values[math.ceil(.95 * len(values))-1]:.1f}"

    def pick(mode, **match):
        return [r for r in samples if r["mode"] == mode
                and all(r[k] in v if isinstance(v, tuple) else r[k] == v for k, v in match.items())]

    lines = ["# Completion benchmark", "", "Times in milliseconds; p50 / p95.", "",
             "| Workload | Mode | n | First popup | Fresh suggestions | Next page | 20 pages | Max timer gap |",
             "|---|---|---:|---:|---:|---:|---:|---:|"]
    for workload in ("cold", "initial", "update", "typing"):
        for mode in modes:
            rows = pick(mode, workload=workload)
            lines.append(f"| {workload} | {mode} | {len(rows)} | " + " | ".join(
                quantile([r.get(key) for r in rows]) for key in
                ("first_ms", "fresh_ms", "page_ms", "pages_total_ms", "max_timer_gap_ms")) + " |")
    lines += ["", "| Prefix | Mode | n | First popup | Fresh | Next page | Candidates | Reply items |",
              "|---|---|---:|---:|---:|---:|---:|---:|"]
    for prefix in ("Bench", "BenchF", "BenchFunc19", "BenchV", "obj.", "obj.Field0", "catalog."):
        for mode in modes:
            rows = pick(mode, prefix=prefix, workload=("initial", "update"))
            lines.append(f"| `{prefix}` | {mode} | {len(rows)} | " + " | ".join(
                quantile([r[key] for r in rows]) for key in
                ("first_ms", "fresh_ms", "page_ms", "candidates", "response_items")) + " |")
    for typed in ("BenchFunc199", "BenchFunc19999", "BenchZZZ"):
      lines += ["", f"Typing \"{typed[5:]}\" at 30 ms intervals into the open \"Bench\" popup:"]
      for mode in modes:
        rows = pick(mode, workload="typing", prefix=typed)
        lags = [lag for r in rows for lag in r["key_lags_ms"]]
        lines.append(f"- {mode}: key lag {quantile(lags)} (n={len(lags)}); "
                     f"no fresh popup within 5 s: {sum(r['timed_out'] is True for r in rows)}/{len(rows)}; "
                     f"fresh after last key {quantile([r['after_last_key_ms'] for r in rows])}; "
                     f"max timer gap {quantile([r['max_timer_gap_ms'] for r in rows])}")
    warm = pick("lazy", workload="cold")
    lines += ["", "Warmup (lazy only, before the user-visible cold row): request "
              f"{quantile([r['warmup_ms'] for r in warm])}, reply items "
              f"{quantile([r['warmup_items'] for r in warm])}, max timer gap "
              f"{quantile([r['warmup_max_gap_ms'] for r in warm])}; n={len(warm)}"]
    (out / "summary.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    print(f"Artifacts: {out}")


if __name__ == "__main__":
    main()
