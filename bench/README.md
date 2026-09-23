# Large-file benchmarks

## Results on this machine

These are the **pre-optimization** results. See [SCALING.md](SCALING.md) for the
new native backend, parallel encoding, and full-load experiments. Also see the
[25 GB single-core rematch](RACE-25GB.md), which includes measured cache residency.

10 GiB (10,737,418,240 bytes), AMD Ryzen 7 5800X, Linux, 32 GiB RAM,
one process pinned to logical CPU 2. Three runs per case; medians below.
Input was a dense file made from an 8 MiB random block repeated 1,280 times.
No compression is performed by either implementation.

Zig 0.16.0, `ReleaseFast`, native CPU target; Rust 1.95.0, release,
`target-cpu=native`; Bao 0.13.1 and BLAKE3 1.8.7 (Cargo.lock included).
Library revision: `a3da1e13836dd9d599018cf3d857cc59e3942066`.
Neither driver uses multithreading or mmap. Timings include process startup,
reading input, hashing, finalization, and flushing output, but not `fsync`.

| Warm-cache operation | Seconds | GiB/s |
| --- | ---: | ---: |
| Zig `hashFile` | 3.640 | 2.747 |
| Rust BLAKE3 hash | 2.818 | 3.549 |
| Zig outboard, file-backed | 3.651 | 2.739 |
| Rust Bao outboard, file-backed | 50.910 | 0.196 |
| Rust Bao outboard, memory-backed then written to file | 15.988 | 0.625 |

Hash-only with input page-cache eviction requested before each run:

| Implementation | Seconds | GiB/s |
| --- | ---: | ---: |
| Zig | 9.621 | 1.039 |
| Rust BLAKE3 | 8.067 | 1.240 |

Eviction uses Linux `POSIX_FADV_DONTNEED`: it is a hint, not proof of cold
physical storage, and does not flush drive caches. Warm input is explicitly read
before each timed run. Implementation order alternates across repetitions.
The machine was not otherwise reserved, and CPU clocks were not fixed by us.

A separate warm-cache Zig baseline-CPU build took 6.865 s (1.457 GiB/s), versus
3.640 s with the native target. Both modules must receive the compiler flags.

### Interpretation

- Rust BLAKE3 delivers about **29% higher hash-only throughput** here. This does
  not establish the fastest implementation of Zig's custom hash construction.
- Zig outboards are **1,310,664 bytes (~1.25 MiB)**, versus Rust Bao's
  **671,088,584 bytes (~640 MiB)**: about 512 times smaller. The algorithms do
  different work: Zig uses 256 KiB hashing chunks and stores non-root internal
  CVs; canonical Bao uses 1 KiB chunks and child-CV pairs in pre-order.
- Rust Bao's file-backed incremental encoder performs a seek/read/write-heavy
  post-order-to-pre-order pass. It used about 28 s of system CPU time per run.
  Keeping the sidecar in a `Cursor<Vec<u8>>` eliminates those file seeks but
  uses ~640 MiB of extra memory. It is much faster, yet still slower than this
  Zig implementation. These are specific encoder-path comparisons, not a
  blanket Rust-versus-Zig performance claim.
- Page-cache eviction makes storage costs substantial. Multicore hashing,
  mmap, verification speed, and other Bao implementations were not benchmarked.

Hash and outboard modes returned identical roots within each implementation
across all runs. Rust's memory/file-backed outboards were byte-identical (`cmp`).
Zig and Rust roots differ, as expected for these different hash constructions.
`zig build test -Doptimize=ReleaseFast` passed.

Raw measurements are in [`results/`](results/). Early calibration runs are not
included in the tables.

## Reproduce

The Zig driver measures `Bao.hashFile` or `Bao.encodeFile` including file I/O.
The current build system configures both modules and the backend options, from
the repository root (current source includes the no-copy optimization; use the
recorded original revision to reproduce the historical implementation):

```sh
zig build bench -Doptimize=ReleaseFast -Dcpu=native -Dnative-kernel=false
cp zig-out/bin/bao-bench /tmp/zig-bao-bench

CARGO_TARGET_DIR=/tmp/bao-rust-target RUSTFLAGS='-C target-cpu=native' \
  cargo build --release --locked --manifest-path bench/rust/Cargo.toml
```

Rust tooling was provided here by `nix shell nixpkgs#cargo nixpkgs#rustc
nixpkgs#gcc`. Use a dedicated work directory and a dense 10 GiB input file.
For example, create one without allocating 10 GiB of RAM:

```sh
mkdir -p /tmp/bao-benchmark
python3 - <<'PY'
import os
block = os.urandom(8 * 1024 * 1024)
with open('/tmp/bao-benchmark/input.bin', 'xb') as f:
    for _ in range(1280):
        f.write(block)
    f.flush()
    os.fsync(f.fileno())
PY

BENCH_CPU=2 python3 bench/run.py /tmp/zig-bao-bench \
  /tmp/bao-rust-target/release/bao-rust-bench \
  /tmp/bao-benchmark/input.bin /tmp/bao-benchmark/warm 3
```

The runner overwrites sidecars and `results.json` in its work directory.
Choose a CPU allowed by your machine's affinity mask. Additional cases:

- `BENCH_CACHE=evict BENCH_MODES=hash`: input eviction before hash-only runs.
- `BENCH_IMPLS=rust BENCH_MODES=outboard-memory`: memory-backed Rust outboard.
- For the Zig baseline case, use `-Dcpu=baseline`; the standalone driver accepts `hash INPUT` or
  `outboard INPUT OUTPUT`.

The Rust hash mode measures the underlying BLAKE3 crate, not Bao encoding.
The default outboard mode buffers file output but forwards seeks and reads to
the file, so the final tree-reordering pass remains file-backed. The memory mode
still streams the input; only the sidecar is retained in RAM before writing it.
