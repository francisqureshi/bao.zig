#!/usr/bin/env python3
"""Single-core file benchmark; pass Zig/Rust executables and input.

python3 bench/run.py ZIG_EXE RUST_EXE INPUT WORKDIR [REPEATS]
Outputs and timings are kept in WORKDIR. No fsync is included in timings.
"""
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import sys
import time

zig, rust, source, workdir = sys.argv[1:5]
repeats = int(sys.argv[5]) if len(sys.argv) > 5 else 3
work = Path(workdir)
work.mkdir(parents=True, exist_ok=True)
size = os.path.getsize(source)
# Inherited by children. No other benchmark processes run concurrently.
core = int(os.environ.get("BENCH_CPU", min(os.sched_getaffinity(0))))
os.sched_setaffinity(0, {core})
cache = os.environ.get("BENCH_CACHE", "warm")
if cache not in ("warm", "evict"):
    raise ValueError("BENCH_CACHE must be warm or evict")
def resident_bytes():
    # Optional Linux cache-residency evidence; never included in timings.
    if not shutil.which("fincore"):
        return None
    probe = subprocess.run(["fincore", "--bytes", "--json", "--output", "RES", source],
                           capture_output=True, text=True)
    if probe.returncode:
        return None
    return json.loads(probe.stdout)["fincore"][0]["res"]


results = []
for repeat in range(repeats):
    implementations = [("zig", zig), ("rust", rust)]
    if repeat % 2:
        implementations.reverse()
    for mode in os.environ.get("BENCH_MODES", "hash outboard").split():
        for name, executable in implementations:
            if name not in os.environ.get("BENCH_IMPLS", "zig rust").split():
                continue
            with open(source, "rb", buffering=0) as f:
                if cache == "warm":
                    while f.read(8 * 1024 * 1024):
                        pass
                else:
                    # Linux hint: request eviction of this input, not global caches.
                    os.posix_fadvise(f.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
            output = work / f"{name}.outboard"
            command = [executable, mode, source]
            if mode.startswith("outboard"):
                command.append(str(output))
            resident_before = resident_bytes()
            before = resource.getrusage(resource.RUSAGE_CHILDREN)
            start = time.perf_counter()
            result = subprocess.run(command, capture_output=True, text=True, check=True)
            elapsed = time.perf_counter() - start
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            row = dict(implementation=name, mode=mode, repeat=repeat + 1,
                       input_bytes=size, cpu=core, cache=cache, seconds=elapsed,
                       resident_bytes_before=resident_before, resident_bytes_after=resident_bytes(),
                       gib_per_second=size / (1024**3) / elapsed,
                       user_seconds=after.ru_utime - before.ru_utime,
                       system_seconds=after.ru_stime - before.ru_stime,
                       output_bytes=output.stat().st_size if mode.startswith("outboard") else 0,
                       stdout=result.stdout.strip(), stderr=result.stderr.strip())
            results.append(row)
            print(json.dumps(row), flush=True)
            (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
