"""Print pooled action latencies and per-process memory from visibility_compare.py."""
import json
import math
import statistics
import sys
from pathlib import Path


def pct95(values):
    return sorted(values)[math.ceil(0.95 * len(values)) - 1]


def stats(cases, key, field):
    rows = [case[field] for case in cases]
    if key == "history300":
        values = [sum(row[f"older{i}"][0] for i in range(1, 11)) for row in rows]
    else:
        values = [v for row in rows for v in row.get(key, [])]
    if not values:
        return "—"
    return f"{statistics.median(values):.2f} / {pct95(values):.2f}"


if __name__ == "__main__":
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("visibility_results.jsonl")
    cases = [json.loads(line) for line in path.read_text().splitlines()]
    for size in sorted({case["entries"] for case in cases}):
        groups = [[c for c in cases if c["entries"] == size and c["mode"] == mode] for mode in ["button", "auto"]]
        print(f"\n{size:,} entries, median / nearest-rank p95")
        for key in ["mount", "stream", "append", "resize", "half_page", "older1", "older10", "history300", "jump", "native_history"]:
            print(f"{key:16s}", *[stats(group, key, "samples") for group in groups], sep=" | ")
        for key in ["stream", "append", "half_page", "history300", "native_history"]:
            print(f"{key+' bytes':16s}", *[stats(group, key, "terminal_bytes") for group in groups], sep=" | ")
        for key in ["seeded", "mounted", "browsed", "peak_matched"]:
            print(f"{key+' MiB':16s}", *[round(statistics.median(c["memory_kib"][key]/1024 for c in group),1) for group in groups], sep=" | ")
        print("buffer rows", *[statistics.median(c["buffer_lines"] for c in group) for group in groups])
        for key in ["partial_pages", "blank_pages"]:
            print(key, sum(c["checks"][key] for c in groups[1]), "/", 40*len(groups[1]))
