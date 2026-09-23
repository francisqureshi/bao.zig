# 25 GB single-core rematch

2026-09-23, current optimized Zig implementation versus the pinned Rust drivers.
Input: **25,000,000,000 bytes** (25 decimal GB / 23.283 GiB), dense file made from
an 8 MiB random block repeated and truncated to the exact length.

## Results

Three runs per case; medians. Each process was restricted to logical CPU 2 on
the Ryzen 7 5800X. GiB/s refers to input bytes processed, not sidecar bytes.

| Operation | Zig | Rust | Zig GiB/s | Rust GiB/s |
| --- | ---: | ---: | ---: | ---: |
| Hash only | 19.22 s | **18.21 s** | 1.21 | 1.28 |
| Hash + outboard | **19.51 s** | 45.50 s | 1.19 | 0.51 |

Rust hash-only is BLAKE3 1.8.7. Rust outboard is Bao 0.13.1's incremental encoder
with a memory-backed `Cursor<Vec<u8>>`, followed by writing the sidecar to a file.
Zig streams its sidecar directly to a buffered file. The much slower Rust
file-backed tree-reordering path was **not rerun** for this rematch.

Sidecars:

- Zig: **3,051,720 bytes** (~3.05 MB).
- Rust: **1,562,499,976 bytes** (~1.56 GB).

The outputs are intentionally different formats/hash constructions, so the
outboard comparison is not equivalent work. Zig was about **2.33× faster** on
this outboard workload. Rust had about **5.5% higher hash-only throughput**.

## Important: these are not fully warm-cache results

The input was read before every timed run, but `fincore` showed only **74–80%**
of it resident immediately before timing. The 25 GB working set did not remain
fully cached on this machine under its current memory conditions. There was
substantial I/O waiting, and Rust's ~1.56 GB sidecar allocation/output also
changes memory pressure. Do not interpret these wall times as isolated hashing
kernel performance or compare them directly with the fully warmed 10 GiB test.

Hash-only median **user CPU time** was much closer: Zig **5.06 s**, Rust **5.20 s**.
That includes all userspace work, not just compression, and is not a substitute
for an isolated kernel benchmark. It is consistent with the earlier finding
that native single-core hashing performance is now similar.

Hash-only implementation order alternated. Outboard cases were run in separate
Zig and Rust groups, not interleaved; cache conditions were not identical.
Input residency was measured before and after each run, outside the timed
section. Raw samples, CPU times and residency are in [`results/25gb/`](results/25gb/).
No global caches were dropped or other system settings changed.

## Builds and checks

- Zig 0.16.0, ReleaseFast, native CPU, `-Dnative-kernel=true`.
- Rust 1.95.0, release, `-C target-cpu=native`, locked Bao/BLAKE3 versions.
- Both are single-core runs with no subtree or cross-file parallelism.
- Input reads, hashing, finalization, output writes and userspace flushes count;
  `fsync`, input generation, warmup and residency probes do not.
- All 28 Zig tests passed before running.
- Roots matched across all runs/modes within each implementation. Sidecar
  headers and exact expected sizes were checked. Cross-implementation roots
  differ as expected. This is not an interoperability test.
- Generated input and sidecars were removed after recording results.

## Commands

```sh
zig build bench test -Doptimize=ReleaseFast -Dcpu=native -Dnative-kernel=true \
  --prefix /tmp/bao-25gb-bench/zig
CARGO_TARGET_DIR=/tmp/bao-rust-bench/target RUSTFLAGS='-C target-cpu=native' \
  cargo build --release --locked --manifest-path bench/rust/Cargo.toml

# ZIG and RUST are the resulting executable paths; INPUT is a dense 25 GB file.
BENCH_CPU=2 BENCH_MODES=hash \
  python3 bench/run.py "$ZIG" "$RUST" "$INPUT" RESULTS/hash 3
BENCH_CPU=2 BENCH_IMPLS=zig BENCH_MODES=outboard \
  python3 bench/run.py "$ZIG" "$RUST" "$INPUT" RESULTS/zig-outboard 3
BENCH_CPU=2 BENCH_IMPLS=rust BENCH_MODES=outboard-memory \
  python3 bench/run.py "$ZIG" "$RUST" "$INPUT" RESULTS/rust-outboard 3
```

`bench/run.py` records Linux `fincore` residency when that utility is available;
otherwise those fields are null. Its `cache: "warm"` field describes the
preparation attempted, **not a guarantee that all input is resident**.
