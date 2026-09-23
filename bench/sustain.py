#!/usr/bin/env python3
"""Compare sustained 8-core/16-thread across-file encoding on generated shards.

Usage: sustain.py EXE DATA_DIR RESULT_DIR [SECONDS_PER_CASE]
This machine's CPU topology is recorded by scale.py; this script requires Linux
CPUs 0..7 to be distinct cores and 8..15 their SMT siblings, and checks it.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time

exe, data_dir, result_dir = sys.argv[1:4]
seconds_per_case = float(sys.argv[4]) if len(sys.argv) > 4 else 30
files = sorted(Path(data_dir).glob("shard-*.bin"))
if len(files) != 16:
    raise SystemExit("Expected exactly 16 generated shards")
result = Path(result_dir)
result.mkdir(parents=True, exist_ok=True)
available = os.sched_getaffinity(0)
cores = [Path(f"/sys/devices/system/cpu/cpu{i}/topology/core_id").read_text().strip() for i in range(16)]
if not set(range(16)).issubset(available) or len(set(cores[:8])) != 8 or cores[:8] != cores[8:]:
    raise SystemExit("Unexpected topology; use scale.py topology detection instead")
size = sum(p.stat().st_size for p in files)
expected = {}
rows = []


def temperatures():
    readings = {}
    for directory in Path('/sys/class/hwmon').glob('hwmon*'):
        try:
            name = (directory / 'name').read_text().strip()
            if name != 'k10temp':
                continue
            for entry in directory.glob('temp*_input'):
                readings[f'{name}/{entry.name}'] = int(entry.read_text()) / 1000
        except (OSError, ValueError):
            pass
    return readings


def encode(path):
    run = subprocess.run([exe, 'outboard', str(path), str(result / (path.name + '.bao'))],
                         capture_output=True, text=True, check=True, timeout=60)
    return path.name, (run.stdout or run.stderr).strip()


for workers in (8, 16):
    os.sched_setaffinity(0, set(range(workers)))
    for path in files:
        with path.open('rb', buffering=0) as f:
            while f.read(8 * 1024 * 1024):
                pass
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    temps_before = temperatures()
    start = time.perf_counter()
    batches = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        while time.perf_counter() - start < seconds_per_case:
            tick = time.perf_counter()
            outputs = list(pool.map(encode, files))
            for name, root in outputs:
                if len(root) != 64 or (name in expected and expected[name] != root):
                    raise AssertionError('Invalid or inconsistent root')
                expected[name] = root
            batches.append(time.perf_counter() - tick)
    elapsed = time.perf_counter() - start
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    row = dict(workers=workers, seconds=elapsed, passes=len(batches), bytes=size * len(batches),
               gib_per_second=size * len(batches) / 1024**3 / elapsed,
               cpu_seconds=after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime,
               batch_seconds=batches, temperatures_before=temps_before, temperatures_after=temperatures())
    rows.append(row)
    print(json.dumps(row), flush=True)
    (result / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
