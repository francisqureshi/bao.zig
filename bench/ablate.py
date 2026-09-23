#!/usr/bin/env python3
"""Compare original, no-copy portable, and native-kernel builds on one file.

Usage: ablate.py ORIGINAL PORTABLE NATIVE INPUT RESULT_DIR
All three binaries accept `outboard INPUT OUTPUT` and print the root.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

original, portable, native, source, directory = sys.argv[1:6]
result = Path(directory)
result.mkdir(parents=True, exist_ok=True)
os.sched_setaffinity(0, {int(os.environ.get('BENCH_CPU', '2'))})
rows = []
expected_root = None
expected_outboard = None
for repeat in range(3):
    variants = [('original', original), ('no-copy', portable), ('native', native)]
    if repeat % 2:
        variants.reverse()
    for name, exe in variants:
        with open(source, 'rb', buffering=0) as f:
            while f.read(8 * 1024 * 1024):
                pass
        output = result / (name + '.bao')
        tick = time.perf_counter()
        run = subprocess.run([exe, 'outboard', source, str(output)],
                             capture_output=True, text=True, check=True, timeout=60)
        elapsed = time.perf_counter() - tick
        root = (run.stdout or run.stderr).strip()
        outboard = output.read_bytes()
        if expected_root is None:
            expected_root, expected_outboard = root, outboard
        assert root == expected_root and outboard == expected_outboard, name
        row = dict(variant=name, repeat=repeat + 1, seconds=elapsed,
                   input_bytes=os.path.getsize(source),
                   gib_per_second=os.path.getsize(source) / 1024**3 / elapsed,
                   root=root, output_bytes=len(outboard))
        rows.append(row)
        print(json.dumps(row), flush=True)
        (result / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
