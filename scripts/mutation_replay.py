#!/usr/bin/env python3
"""Replay the Olympix mutation list against the current test suite.

The auditor's CSV records, for each mutant, the exact source line, the original
expression and the mutated expression. This script re-applies those mutations
to a scratch copy of the repository and runs `forge test` for each one.

Classification:
  killed   - the suite failed
  survived - the suite passed
  invalid  - the mutant did not compile (excluded from the score)
  stale    - the mutated expression no longer exists in the source (excluded)

Usage:
  python3 scripts/mutation_replay.py \
    --csv "/mnt/c/Users/SciPhii/Downloads/Centiiv - Mutation Testing Results.csv" \
    --repo . --workdir /tmp/arc-mut

The working tree is never modified: `src`, `test`, `script` and `foundry.toml`
are copied to `--workdir` and `lib` is symlinked.
"""

import argparse
import csv
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


def choose_match(text: str, needle: str, expected_line: int) -> int | None:
    """Return the byte offset of the occurrence closest to `expected_line`."""
    positions = []
    start = 0
    while True:
        idx = text.find(needle, start)
        if idx == -1:
            break
        positions.append(idx)
        start = idx + 1
    if not positions:
        return None
    return min(positions, key=lambda idx: abs(text.count("\n", 0, idx) + 1 - expected_line))


def choose_regex_match(text: str, needle: str, expected_line: int):
    pattern = re.compile(r"\s+".join(re.escape(part) for part in needle.split()))
    matches = list(pattern.finditer(text))
    if not matches:
        return None
    return min(matches, key=lambda m: abs(text.count("\n", 0, m.start()) + 1 - expected_line))


def prepare_workdir(repo: Path, workdir: Path) -> None:
    if workdir.exists():
        shutil.rmtree(workdir)
    workdir.mkdir(parents=True)
    for name in ("src", "test", "script"):
        shutil.copytree(repo / name, workdir / name)
    shutil.copy2(repo / "foundry.toml", workdir / "foundry.toml")
    # The fork rehearsal needs a live RPC and is irrelevant to mutants.
    shutil.rmtree(workdir / "test" / "fork", ignore_errors=True)
    lib = workdir / "lib"
    if lib.exists() or lib.is_symlink():
        lib.unlink()
    os.symlink(repo / "lib", lib)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", required=True)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--workdir", default="/tmp/arc-mut")
    parser.add_argument("--out", default="/tmp/mutation-replay.csv")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--shard", type=int, default=0)
    parser.add_argument("--shards", type=int, default=1)
    parser.add_argument(
        "--forge",
        default=os.environ.get("FORGE", str(Path.home() / ".foundry" / "bin" / "forge")),
    )
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    workdir = Path(args.workdir)
    prepare_workdir(repo, workdir)

    rows = list(csv.DictReader(open(args.csv, encoding="utf-8-sig"), delimiter=";"))
    rows = [row for row in rows if row["File"].startswith("src/")]
    if args.shards > 1:
        if args.shard < 0 or args.shard >= args.shards:
            print("--shard must be in [0, --shards)", file=sys.stderr)
            return 2
        rows = rows[args.shard :: args.shards]
    if args.limit:
        rows = rows[: args.limit]

    results = []
    counts = {"killed": 0, "survived": 0, "invalid": 0, "stale": 0}

    for index, row in enumerate(rows, 1):
        rel = row["File"]

        expected_line = int(row["Line Number"])
        original = row["Original Code"]
        mutated = row["Mutated Code"]
        target = workdir / rel
        backup = target.read_text(encoding="utf-8")

        position = choose_match(backup, original, expected_line)
        if position is None:
            match = choose_regex_match(backup, original, expected_line)
            if match is None:
                counts["stale"] += 1
                results.append((rel, expected_line, "stale", "expression no longer present", row))
                print(f"[{index}/{len(rows)}] STALE {rel}:{expected_line}", flush=True)
                continue
            position = match.start()
            length = match.end() - match.start()
        else:
            length = len(original)

        target.write_text(
            backup[:position] + mutated + backup[position + length :],
            encoding="utf-8",
        )

        try:
            proc = subprocess.run(
                [args.forge, "test", "--offline"],
                cwd=workdir,
                capture_output=True,
                text=True,
                timeout=900,
            )
            output = (proc.stdout or "") + (proc.stderr or "")
            if "Compiler run failed" in output or "Error: Compiler run failed" in output:
                status = "invalid"
                counts["invalid"] += 1
            elif proc.returncode == 0:
                status = "survived"
                counts["survived"] += 1
            else:
                status = "killed"
                counts["killed"] += 1
        finally:
            target.write_text(backup, encoding="utf-8")

        expected = "killed" if row["Was Mutation Killed?"].strip().lower() == "true" else "survived"
        note = "" if status == expected else f"(was {expected})"
        results.append((rel, expected_line, status, note, row))
        print(
            f"[{index}/{len(rows)}] {status.upper():8} {rel}:{expected_line} {note}",
            flush=True,
        )

    with open(args.out, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["file", "line", "status", "note", "original", "mutated"])
        for rel, line, status, note, row in results:
            writer.writerow([rel, line, status, note, row["Original Code"], row["Mutated Code"]])

    scored = counts["killed"] + counts["survived"]
    score = (counts["killed"] / scored * 100) if scored else 0.0
    print("")
    print(f"killed={counts['killed']} survived={counts['survived']} invalid={counts['invalid']} stale={counts['stale']}")
    print(f"mutation score: {score:.1f}% over {scored} valid mutants")
    print(f"details: {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
