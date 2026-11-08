#!/usr/bin/env bash
# Run scripts/mutation_replay.py in parallel shards and merge the results.
#
#   SHARDS=3 ./scripts/run-mutation-shards.sh "/path/to/mutation results.csv"
#
# Set FORGE if forge is not on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CSV="${1:?usage: run-mutation-shards.sh <csv> [shards]}"
SHARDS="${2:-${SHARDS:-3}}"
FORGE="${FORGE:-forge}"
OUT="${OUT:-/tmp/mutation-replay.csv}"

rm -rf /tmp/arc-mut-* /tmp/mutation-*.csv /tmp/mutation-*.log

pids=()
for i in $(seq 0 $((SHARDS - 1))); do
    (
        FORGE="$FORGE" python3 scripts/mutation_replay.py \
            --csv "$CSV" \
            --repo "$ROOT" \
            --workdir "/tmp/arc-mut-$i" \
            --out "/tmp/mutation-$i.csv" \
            --shard "$i" \
            --shards "$SHARDS" \
            > "/tmp/mutation-$i.log" 2>&1
    ) &
    pids+=("$!")
done

status=0
for pid in "${pids[@]}"; do
    wait "$pid" || status=1
done

python3 - "$SHARDS" "$OUT" <<'PY'
import csv, glob, sys

shards = int(sys.argv[1])
out = sys.argv[2]
rows = []
for shard in range(shards):
    path = f"/tmp/mutation-{shard}.csv"
    try:
        rows.extend(list(csv.DictReader(open(path, encoding="utf-8"))))
    except FileNotFoundError:
        pass

with open(out, "w", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(
        handle, fieldnames=["file", "line", "status", "note", "original", "mutated"]
    )
    writer.writeheader()
    writer.writerows(rows)

counts = {}
for row in rows:
    counts[row["status"]] = counts.get(row["status"], 0) + 1
scored = counts.get("killed", 0) + counts.get("survived", 0)
score = (counts.get("killed", 0) / scored * 100) if scored else 0.0
print("")
print(
    f"killed={counts.get('killed', 0)} survived={counts.get('survived', 0)} "
    f"invalid={counts.get('invalid', 0)} stale={counts.get('stale', 0)}"
)
print(f"mutation score: {score:.1f}% over {scored} valid mutants")
print(f"details: {out}")
for row in rows:
    if row["status"] in ("survived", "invalid", "stale"):
        print(f"  {row['status'].upper():8} {row['file']}:{row['line']} {row['note']}")
PY

exit "$status"
