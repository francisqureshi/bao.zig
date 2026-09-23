#!/usr/bin/env python3
"""Bounded Linux load experiment: single-file and across-file outboard generation.

Usage: scale.py EXE DATA_DIR RESULT_DIR [SECONDS_BUDGET]
Requires large.bin plus shard-*.bin in DATA_DIR. Never scans arbitrary trees.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import resource
import statistics
import subprocess
import sys
import time

exe, data_dir, result_dir = sys.argv[1:4]
budget = float(sys.argv[4]) if len(sys.argv) > 4 else 420
start_experiment = time.monotonic()
data, result = Path(data_dir), Path(result_dir)
result.mkdir(parents=True, exist_ok=True)
large = data / "large.bin"
shards = sorted(data.glob("shard-*.bin"))
if not large.is_file() or not shards:
    raise SystemExit("Missing generated dataset")
available = os.sched_getaffinity(0)
# Physical cores first, then their SMT siblings, discovered from Linux sysfs.
groups = {}
for cpu in sorted(available):
    topology = Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
    key = (int((topology / "physical_package_id").read_text()),
           int((topology / "core_id").read_text()))
    groups.setdefault(key, []).append(cpu)
order = [cpus[0] for cpus in groups.values()] + [c for cpus in groups.values() for c in cpus[1:]]
rows = []
expected = {}


def prepare(files, cache):
    for path in files:
        with path.open("rb", buffering=0) as f:
            if cache == "warm":
                while f.read(8 * 1024 * 1024):
                    pass
            else:
                os.posix_fadvise(f.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)


def encode(path, workers, parallel):
    output = result / (path.name + ".bough")
    command = [exe, "parallel" if parallel else "outboard", str(path), str(output)]
    if parallel:
        command.append(str(workers))
    run = subprocess.run(command, capture_output=True, text=True, check=True, timeout=120)
    root = (run.stdout or run.stderr).strip()
    if len(root) != 64:
        raise ValueError(f"Unexpected digest: {root}")
    return path.name, root, output.stat().st_size


# Alternate ascending/descending worker order. No timing overlaps between cases.
for repeat in range(int(os.environ.get("BENCH_REPEATS", "2"))):
    counts = [int(n) for n in os.environ.get("BENCH_WORKERS", "1 2 4 8 16").split() if int(n) <= len(order)]
    if repeat:
        counts.reverse()
    for cache in os.environ.get("BENCH_CACHES", "warm evict").split():
        for workload, files in (("single-file", [large]), ("across-files", shards)):
            if workload not in os.environ.get("BENCH_WORKLOADS", "single-file across-files").split():
                continue
            for workers in counts:
                if time.monotonic() - start_experiment > budget - 25:
                    print("Budget reached; remaining cases explicitly skipped", flush=True)
                    (result / "budget-stopped.txt").write_text("Remaining cases skipped to respect time budget.\n")
                    raise SystemExit(0)
                cpus = order[:min(workers, int(os.environ.get("BENCH_AFFINITY_LIMIT", str(len(order)))))]
                os.sched_setaffinity(0, cpus)
                prepare(files, cache)
                before = resource.getrusage(resource.RUSAGE_CHILDREN)
                start = time.perf_counter()
                if workload == "single-file":
                    outputs = [encode(large, workers, True)]
                else:
                    # External file-level scheduler: no nested per-file worker pools.
                    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
                        outputs = list(pool.map(lambda p: encode(p, 1, False), files))
                elapsed = time.perf_counter() - start
                after = resource.getrusage(resource.RUSAGE_CHILDREN)
                for name, root, _ in outputs:
                    if name in expected and expected[name] != root:
                        raise AssertionError(f"Root mismatch for {name}")
                    expected[name] = root
                size = sum(p.stat().st_size for p in files)
                row = dict(repeat=repeat + 1, cache=cache, workload=workload,
                           workers=workers, cpus=cpus, input_bytes=size, seconds=elapsed,
                           gib_per_second=size / 1024**3 / elapsed,
                           cpu_seconds=(after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime),
                           output_bytes=sum(o[2] for o in outputs), roots=dict((o[0], o[1]) for o in outputs))
                rows.append(row)
                print(json.dumps({k: v for k, v in row.items() if k != "roots"}), flush=True)
                (result / "results.json").write_text(json.dumps(rows, indent=2) + "\n")
print(f"Completed in {time.monotonic() - start_experiment:.1f}s", flush=True)
