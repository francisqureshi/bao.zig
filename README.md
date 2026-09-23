# bao.zig

Bao-inspired hashing and verification for large-file sync, written in Zig 0.16.0 with no dependencies.

- Streaming hashing and compact Merkle-tree sidecars (outboards).
- Byte-range proof extraction and verification, plus streaming content verification.
- SIMD chunk hashing, optional upstream AVX2 assembly, and bounded parallel file encoding.

**Not compatible with upstream Bao or its wire format.** Uses custom 256 KiB hashing chunks and post-order outboards. Hashes match standard BLAKE3 only for inputs up to 1 KiB; larger inputs use a non-standard hash construction.

The library module is `bao.zig`; public APIs live in [`src/Bao.zig`](src/Bao.zig).

```sh
zig build test
```

For native AVX2 on x86_64 Linux: `zig build bench -Doptimize=ReleaseFast -Dcpu=native -Dnative-kernel=true`.

See [optimization and 8-core/16-thread benchmarks](bench/SCALING.md), including the [original Rust comparison](bench/README.md).
