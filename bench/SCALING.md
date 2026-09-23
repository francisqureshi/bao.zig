# Optimized hashing and full-load experiment

## Changes tested

- Removed the per-batch carry copy from `encodeSubtreeCore`. The declared length
  already identifies the final chunk, so lookahead/copying is unnecessary.
- Added an **opt-in** upstream BLAKE3 1.8.7 AVX2 assembly backend, invoked with
  4096 blocks per custom 256 KiB chunk. Scalar and Zig-vector paths remain.
- Added `Bough.Parallel.encodeFile`: 1–16 bounded worker threads, disjoint
  positional reads/writes, then positional subtree assembly. It does not load
  a whole file or outboard into memory. Each worker reserves a 16 MiB stack;
  segment roots are bounded by the worker count. All workers are joined before
  returning, including error paths.
- Added across-file scheduling experiments using Python-controlled processes.
  This is a benchmark harness, **not a production recursive filesystem scanner**.

No hash, chunk-size, or sidecar-format change. Generated large-file outboards
were compared byte-for-byte against the original executable, not merely against
another new code path. All retained across-file and sustained outputs also
matched the original. Debug/ReleaseFast tests passed with the native backend;
ReleaseFast tests passed with native disabled and on the baseline CPU target.
The suite contains 28 tests, including scalar/native comparisons, custom keys,
counter carry through 2^32, short input, trailing bytes, uneven parallel splits,
invalid worker counts, and non-regular-file rejection.

## Environment and scope

AMD Ryzen 7 5800X, 8 physical cores / 16 logical CPUs, 32 GiB RAM, Linux/ext4,
one Sabrent Rocket Q4 NVMe. CPU governor was `powersave`, boost disabled; we did
not change either. Zig 0.16.0, ReleaseFast, native CPU target. CPU IDs 0–7 are
one hardware thread per core; 8–15 are their SMT siblings.

Only generated local files were accessed: one dense **10 GiB** file and
**16 × 512 MiB** files (8 GiB total). An 8 MiB random block was repeated to make
these; equal-size files had equal contents, but every byte was read and hashed
on every pass. No deduplication or compression occurs in these benchmarks.
No real filesystem tree or 130 TB dataset was scanned. Temporary data is removed
after validation. Raw results and environment: [`results/scaling/`](results/scaling/).

All main workload cases produce **both roots and outboards**. Times include
startup, input reads, hashing, output writes, assembly and userspace flushing;
not `fsync`, metadata walking, network transfer, or atomic publication.

- **Warm:** explicitly read inputs before timing; this measures cached data.
- **Evict:** request per-file page-cache eviction using `POSIX_FADV_DONTNEED`.
  This is a hint, not proof of cold physical media; drive caches remain.
- Core scaling used two repetitions in opposite worker-count orders.
- Single-core ablation used three repetitions, alternating variant order.
- Sustained runs lasted ~30 seconds each, repeatedly encoding all 16 files.
- The main scaling experiment took 149.6 s, sustained runs 60.4 s, and the
  additional I/O-concurrency check 9.2 s. Together with calibration/ablation and
  Rust recheck, load experiments stayed comfortably under the 10-minute limit.

## Single-core improvements

Warm 10 GiB file, root **and** outboard, pinned to CPU 2; median of three:

| Build | Seconds | GiB/s |
| --- | ---: | ---: |
| Original (`a3da1e1`) | 3.604 | 2.775 |
| Remove carry copies; existing Zig vector kernel | 3.306 | 3.025 |
| Also enable upstream AVX2 kernel | 2.732 | 3.660 |

About **9%** higher throughput from removing copies; **32% overall** with the
native backend. All three produced the same 1,310,664-byte outboard and root.
A separate same-input, same-core hash-only recheck gave optimized Zig **2.773 s
(3.606 GiB/s)** versus Rust BLAKE3 **2.819 s (3.547 GiB/s)**. Treat that ~2%
difference as effectively similar throughput, not a universal win: the hash
constructions still differ and sample sizes are small.

## Core scaling

Throughput is total input bytes divided by median elapsed time (two runs).
"Workers" means threads inside one file, or simultaneous single-threaded
processes for the across-file case. Across-file cases do not nest per-file pools.

| Workers / allowed logical CPUs | 10 GiB single file, warm | 10 GiB single file, eviction requested | 16 files, eviction requested |
| --- | ---: | ---: | ---: |
| 1 / one physical core | 3.59 GiB/s | 1.26 GiB/s | 1.26 GiB/s |
| 2 / two physical cores | 6.00 GiB/s | 1.24 GiB/s | 1.60 GiB/s |
| 4 / four physical cores | 8.91 GiB/s | 1.83 GiB/s | 2.72 GiB/s |
| 8 / eight physical cores | **16.38 GiB/s** | 2.34 GiB/s | 3.92 GiB/s |
| 16 / all SMT threads | 9.61 GiB/s | **3.22 GiB/s** | **4.51 GiB/s** |

The single-file split uses power-of-two segments, so a 10 GiB file isn't evenly
balanced across eight workers. Across-file scheduling has a different balance.
The warm across-file 1-worker case was noisy (2.42–5.27 s); raw samples are kept,
not silently removed. Main conclusions rely on repeated/sustained 8-vs-16 runs.

### Sustained cached-data saturation

| Configuration | Wall time | Data processed | Throughput | Average occupied logical CPUs |
| --- | ---: | ---: | ---: | ---: |
| 8 workers on 8 physical cores | 30.12 s | 672 GiB | **22.31 GiB/s** | 7.39 / 8 |
| 16 workers on all logical CPUs | 30.31 s | 288 GiB | **9.50 GiB/s** | 14.22 / 16 |

These totals represent repeated reads of the **same cached 8 GiB**, not unique
storage reads. More CPU utilization did not mean more useful work. Eight cores
were about **2.35× faster** here. End-point CPU temperature readings were below
50°C; continuous thermal/frequency sampling was not done. SMT/cache/resource
contention is a plausible explanation, **not a profiled diagnosis**.

### I/O concurrency is separate from core count

An additional three-run test allowed **16 simultaneous files but only CPUs 0–7**:

- Warm median: **11.18 GiB/s** (slower than eight workers on cached data).
- Eviction-requested median: **4.51 GiB/s**, essentially identical to using all
  16 logical CPUs, without needing SMT execution.

Thus the storage benefit from 16 jobs does not require 16 active hardware
threads on this machine. Separating read-ahead/I/O depth from CPU hashing
parallelism is a promising next step; that pipeline is **not implemented here**.

## What this means for 130 TB

Start with **eight hashing workers, one per physical core**. For an actual
storage scan, tune concurrent reads/files separately: 16 in-flight files helped
this NVMe, while compute-heavy cached runs strongly preferred eight workers.
Use a single global concurrency budget; do not start 16 subtree workers inside
each of 16 concurrent files. HDD arrays, network storage, small files, and
fragmented data may prefer very different queue depths and read patterns.

For **130 decimal TB**, ignoring metadata and other overhead:

| Sustained end-to-end throughput | Arithmetic scan time |
| --- | ---: |
| 1 GiB/s | 33.6 hours |
| 2 GiB/s | 16.8 hours |
| 4.51 GiB/s (this local eviction-requested peak) | 7.5 hours |

The last row is **not a prediction for the target filesystem**. It requires
sustaining that rate over the entire dataset, which this short local experiment
does not demonstrate. Expect roughly **15.9 GB of sidecars** for 130 TB made up
of large files under the current format; small-file overhead changes the ratio.

Before a real scan: identify storage topology and file-size distribution, test a
representative subset, and use stable files or a filesystem snapshot. Parallel
encoding requires distinct regular input/output files and stable content;
errors leave incomplete sidecars, so a production caller should write to a
temporary sidecar and publish it only after successful completion. Checkpointing,
resume, changing-file detection, durability, and a directory walker are not
implemented by this experiment.

## Build and reproduce

From repository root:

```sh
# Native backend is opt-in and currently supports x86_64 Linux with AVX2.
zig build bench -Doptimize=ReleaseFast -Dcpu=native -Dnative-kernel=true
zig build test -Doptimize=ReleaseFast -Dcpu=native -Dnative-kernel=true

# Root + outboard, with a bounded within-file worker pool:
zig-out/bin/bough-bench parallel INPUT OUTPUT 8
# Existing sequential path:
zig-out/bin/bough-bench outboard INPUT OUTPUT
```

These benchmark commands overwrite OUTPUT; it must never alias INPUT. Build
with `-Dnative-kernel=false` for the portable Zig-vector implementation.
The native backend is compile-target selected, not runtime-dispatched: do not
run a native-target binary on an incompatible CPU. Vendoring/provenance/licenses
are documented in [`../vendor/blake3/README.md`](../vendor/blake3/README.md).

`scale.py` expects only `large.bin` and `shard-*.bin` in a dedicated data directory;
`sustain.py` expects exactly 16 shards and checks this machine's CPU topology.
Generate the dataset with the same pattern as the earlier benchmark (see
[README.md](README.md)), using 1280 repetitions for `large.bin`, 64 for each
`shard-00.bin` through `shard-15.bin`, and `fsync` before starting. Then:

```sh
python3 bench/scale.py zig-out/bin/bough-bench DATA RESULTS/scaling 400
python3 bench/sustain.py zig-out/bin/bough-bench DATA RESULTS/sustained 30
BENCH_WORKERS=16 BENCH_WORKLOADS=across-files BENCH_REPEATS=3 \
  BENCH_AFFINITY_LIMIT=8 python3 bench/scale.py \
  zig-out/bin/bough-bench DATA RESULTS/io-concurrency 90
```

The scaling script discovers CPU topology, warms/evicts input per case, records
roots and timing, and stops scheduling new cases near its time budget. Results
and sidecars in each result directory are overwritten on subsequent runs.
`bench/ablate.py` compares saved original, no-copy, and native executables and
asserts byte-identical outboards; `bench/run.py` retains the Rust comparison.
