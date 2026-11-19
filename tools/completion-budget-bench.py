#!/usr/bin/env python3
"""Compare gopls completion budgets and preparation on the existing GUI fixture.

No client completion cache is reused. Every condition starts a fresh Emacs and
gopls with an empty gopls disk cache; the Go build cache is shared and primed.
Immediate: request after initialization. Idle: let the valid open file sit for
two seconds. Prefetch: request the same prefix, discard the response, edit the
prefix again, then measure a new RPC. Only budget-first is a first request;
subsequent prefixes measure already-used servers. Time includes transport and
JSON decoding in Emacs, not just server computation. Display uses synchronous
Eglot + Corfu in every condition, with no artificial idle delay.
"""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import runpy
import statistics
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--budgets", default="100,20,5,1", help="milliseconds; must include 100")
    parser.add_argument("--emacs", default="/Applications/MacPorts/Emacs.app/Contents/MacOS/Emacs")
    parser.add_argument("--go", default="/usr/local/go/bin/go")
    parser.add_argument("--gopls", default=str(Path.home() / "go/bin/gopls"))
    args = parser.parse_args()
    budgets = [int(value) for value in args.budgets.split(",")]
    if args.rounds < 1 or 100 not in budgets or any(b <= 0 for b in budgets):
        parser.error("Use positive rounds and budgets, including the 100 ms reference")
    out = (args.output or Path(tempfile.mkdtemp(prefix="completion-budget-"))).resolve()
    out.mkdir(parents=True, exist_ok=True)
    tools = Path(__file__).resolve().parent
    root = out / "fixture"
    runpy.run_path(str(tools / "completion-bench.py"))["fixture"](root)
    env = os.environ.copy()
    env.update(PATH=f"{Path(args.go).parent}:{Path(args.gopls).parent}:" + env["PATH"],
               GOTOOLCHAIN="local", GOCACHE=str(out / "go-build-cache"),
               GOMODCACHE=str(out / "go-mod-cache"), COMPLETION_BENCH_ROOT=str(root),
               COMPLETION_BENCH_MODE="sync", COMPLETION_BENCH_ROUNDS="0",
               COMPLETION_BENCH_GOPLS=args.gopls)
    subprocess.run([args.go, "test", "./..."], cwd=root, env=env, check=True)
    order = []
    randomizer = random.Random(20261119)
    for repeat in range(args.rounds):
        conditions = list(itertools.product(budgets, ("immediate", "idle", "prefetch")))
        randomizer.shuffle(conditions)
        order.extend((repeat, budget, prep) for budget, prep in conditions)
    metadata = dict(variables=1000, functions=20000, order=order,
                    go=subprocess.check_output([args.go, "version"], text=True).strip(),
                    gopls=subprocess.check_output([args.gopls, "version"], text=True).strip(),
                    source_sha256={name: hashlib.sha256((tools / name).read_bytes()).hexdigest()
                                   for name in ("completion-budget-bench.py", "completion-bench.py", "completion-bench.el")})
    (out / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    samples = []
    identities = {}
    for number, (repeat, budget, prep) in enumerate(order):
        run = out / f"{number:02d}-{budget}ms-{prep}"
        run.mkdir()
        env.update(COMPLETION_BENCH_OUT=str(run), COMPLETION_BENCH_BUDGET=f"{budget}ms",
                   COMPLETION_BENCH_WARMUP=prep, GOPLSCACHE=str(run / "gopls-cache"))
        print(f"{number+1}/{len(order)}: {budget} ms, {prep}, repeat {repeat+1}", flush=True)
        with (run / "emacs.log").open("w") as log:
            proc = subprocess.Popen([args.emacs, "-Q", "-l", str(tools / "completion-bench.el")],
                                    env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                status = proc.wait(timeout=120)
            except BaseException:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                raise
        if status:
            raise RuntimeError(f"Emacs exited {status}; see {run}")
        settings = json.loads((run / "settings.json").read_text())
        assert settings["initialization"]["completionBudget"] == f"{budget}ms", settings
        assert settings["workspace"]["gopls"]["completionBudget"] == f"{budget}ms", settings
        rows = json.loads((run / "results.json").read_text())
        assert len(rows) == 7, (run, len(rows))
        for row in rows:
            assert row["requests"] == 1, row  # never satisfied from a client cache
            assert 0 < row["visible_rows"] <= 10, row
            assert 0 <= row["rpc_ms"] <= row["reply_ms"] <= row["fresh_ms"], row
            labels = json.loads((run / row["labels_file"]).read_text())
            assert len(labels) == row["response_items"], row
            key = (repeat, prep, row["workload"], row["prefix"])
            identities[(budget, *key)] = set(labels)
            row.update(budget_ms=budget, repeat=repeat, run=run.name)
            samples.append(row)
        first = rows[0]
        print(f"  first RPC {first['rpc_ms']:.0f} ms, popup {first['first_ms']:.0f} ms, "
              f"{first['response_items']} candidates", flush=True)
    for row in samples:
        key = (row["repeat"], row["warmup"], row["workload"], row["prefix"])
        reference = identities[(100, *key)]
        actual = identities[(row["budget_ms"], *key)]
        row.update(reference_count=len(reference), lost=len(reference - actual),
                   gained=len(actual - reference), lost_pct=100 * len(reference - actual) / len(reference))
    (out / "results.json").write_text(json.dumps(samples, indent=2) + "\n")
    def timing(rows, key):
        vals = [row[key] for row in rows]
        return f"{statistics.median(vals):.0f} [{min(vals):.0f}–{max(vals):.0f}]"
    lines = ["# Gopls completion budget and warmup", "", __doc__, "",
             "Times: median [min–max], milliseconds. Loss compares candidate identities with the",
             "100 ms run of the same preparation, prefix and repetition. Warmup cost excludes connection.", "",
             "| Preparation | Budget | n | Preparation cost | First RPC | First popup | Candidates | Lost vs 100 ms |",
             "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for prep, budget in itertools.product(("immediate", "idle", "prefetch"), budgets):
        rows = [r for r in samples if r["workload"] == "budget-first" and r["warmup"] == prep
                and r["budget_ms"] == budget]
        lines.append(f"| {prep} | {budget} | {len(rows)} | " + " | ".join(
            timing(rows, key) for key in ("warmup_ms", "rpc_ms", "first_ms", "response_items", "lost")) + " |")
    lines += ["", "Follow-up queries (server already used; preparations pooled):", "",
              "| Prefix | Budget | n | RPC | Popup | Candidates | Lost | Gained |",
              "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for prefix, budget in itertools.product(("BenchF", "BenchFunc19", "BenchV", "obj.", "catalog."), budgets):
        rows = [r for r in samples if r["prefix"] == prefix and r["budget_ms"] == budget]
        lines.append(f"| `{prefix}` | {budget} | {len(rows)} | " + " | ".join(
            timing(rows, key) for key in ("rpc_ms", "first_ms", "response_items", "lost", "gained")) + " |")
    (out / "summary.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    print(f"Artifacts: {out}")


if __name__ == "__main__":
    main()
