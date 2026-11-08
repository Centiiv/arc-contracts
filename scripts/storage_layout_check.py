#!/usr/bin/env python3
"""Storage-layout regression gate.

Compares a previously released layout against the layout produced by the
current source tree. The rule the proxies rely on is:

  * every non-gap variable keeps its name, slot, offset and type;
  * a new variable may only occupy slots that were previously reserved by a
    ``__gap`` (or slots beyond the end of the old layout);
  * ``__gap`` may shrink, but the layout may never shrink overall.

Usage:
    python3 scripts/storage_layout_check.py prev.json next.json
"""

import json
import sys


def load(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    return data["storage"], data.get("types", {})


def human_type(entry, types):
    return types.get(entry["type"], {}).get("label", entry["type"])


def slot_span(entry, types):
    """Number of 32-byte slots a top-level declaration occupies."""
    meta = types.get(entry["type"], {})
    encoding = meta.get("encoding")
    if encoding == "mapping" or encoding == "dynamicArray":
        return 1
    if "numberOfBytes" in meta:
        size = int(meta["numberOfBytes"])
        return max(1, (size + 31) // 32)
    # In-place structs are not expected at the top level; treat as one slot.
    return 1


def is_gap(label):
    return label.startswith("__gap")


def ranges(entries, types):
    out = {}
    for entry in entries:
        start = int(entry["slot"])
        out[entry["label"]] = (start, start + slot_span(entry, types))
    return out


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: storage_layout_check.py <previous.json> <current.json>", file=sys.stderr)
        return 2

    prev, prev_types = load(sys.argv[1])
    next_, next_types = load(sys.argv[2])

    errors = []
    prev_ranges = ranges(prev, prev_types)
    next_ranges = ranges(next_, next_types)

    prev_by_label = {entry["label"]: entry for entry in prev}
    next_by_label = {entry["label"]: entry for entry in next_}

    # 1. Every pre-existing non-gap variable must be untouched.
    reserved = []
    for label, entry in prev_by_label.items():
        if is_gap(label):
            continue
        start, end = prev_ranges[label]
        reserved.append((label, start, end))

        current = next_by_label.get(label)
        if current is None:
            errors.append(f"removed storage variable: {label} (slot {entry['slot']})")
            continue
        if current["slot"] != entry["slot"] or current["offset"] != entry["offset"]:
            errors.append(
                f"moved storage variable: {label} "
                f"{entry['slot']}:{entry['offset']} -> {current['slot']}:{current['offset']}"
            )
        if human_type(current, next_types) != human_type(entry, prev_types):
            errors.append(
                f"changed type of {label}: "
                f"{human_type(entry, prev_types)} -> {human_type(current, next_types)}"
            )

    # 2. Anything new must sit in previously reserved gap space or beyond it.
    for label, (start, end) in next_ranges.items():
        if label in prev_by_label:
            continue
        for reserved_label, rstart, rend in reserved:
            if start < rend and rstart < end:
                errors.append(
                    f"new variable {label} (slots {start}-{end - 1}) overlaps "
                    f"{reserved_label} (slots {rstart}-{rend - 1})"
                )

    # 3. The layout must not shrink.
    prev_end = max((end for _, end in prev_ranges.values()), default=0)
    next_end = max((end for _, end in next_ranges.values()), default=0)
    if next_end < prev_end:
        errors.append(f"layout shrank from {prev_end} to {next_end} slots")

    if errors:
        print("storage layout check FAILED", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    print(
        f"storage layout OK ({len(next_)} declarations, {next_end} slots; "
        f"previously {prev_end})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
