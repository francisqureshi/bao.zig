# Vendored BLAKE3 AVX2 kernel

`blake3_avx2_x86-64_unix.S` is an **unchanged** copy of the upstream
`c/blake3_avx2_x86-64_unix.S` from the Rust `blake3` crate, version 1.8.7
(https://crates.io/crates/blake3/1.8.7; upstream source at
https://github.com/BLAKE3-team/BLAKE3). The source was copied from the local
Cargo registry. SHA-256: `a2d95519fd9845cf80252110e21a93124e81c03da836eaac0bca0537be4f8324`.

Upstream licenses, included verbatim here: `LICENSE_CC0` (CC0-1.0),
`LICENSE_A2` (Apache-2.0), and `LICENSE_A2LLVM` (Apache-2.0 with LLVM
exception). Upstream offers these as alternatives.

The exported `blake3_hash_many_avx2` routine compresses independent input
chunks with a caller-supplied block count and key. Bao uses 4096 blocks per
256 KiB chunk (not upstream's default 1024-byte chunk) and does not use this
routine for ROOT chunks. Build with `-Dnative-kernel=true` only for an
x86_64 Linux target with AVX2 enabled; the default build uses Zig's vector
kernel instead.
