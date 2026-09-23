# bough.zig

Bao-inspired hashing and verification for large-file sync, written in Zig 0.16.0 with no dependencies.

- Streaming hashing and compact Merkle-tree sidecars (outboards).
- Byte-range proof extraction and verification, plus streaming content verification.
- SIMD chunk hashing, optional upstream AVX2 assembly, and bounded parallel file encoding.

**Not compatible with upstream Bao or its wire format.** Uses custom 256 KiB hashing chunks and post-order outboards. Hashes match standard BLAKE3 only for inputs up to 1 KiB; larger inputs use a non-standard hash construction.

The library module is `bough.zig`; public APIs live in [`src/Bough.zig`](src/Bough.zig).

Previously named `bao.zig`. The rename changes package/import names, not hashes or sidecar bytes. Existing consumers should re-fetch the dependency as `bough` from [francisqureshi/bough.zig](https://github.com/francisqureshi/bough.zig) and update imports; the renamed package has a new Zig fingerprint.

```sh
zig build test
```

## Using as a dependency

With the package registered as `bough` in your application's `build.zig.zon`, add this to its `build.zig` (using your target, optimization mode, and executable):

```zig
const bough = b.dependency("bough", .{
    .target = target,
    .optimize = optimize,
    .@"native-kernel" = true,
});
exe.root_module.addImport("bough.zig", bough.module("bough.zig"));
```

Application code uses `const Bough = @import("bough.zig");`. The assembly links automatically; no separate C library is needed. Omit `native-kernel` or set it to `false` for the portable Zig backend (the default). Both backends produce identical hashes and outboards.

**Native backend requirements:** x86_64 Linux and a build target with AVX2 enabled. Selection is compile-time, **not runtime CPU detection**. Build on the deployment machine with `-Dcpu=native -Doptimize=ReleaseFast`, or select a target compatible with every deployment CPU. A binary built for one machine's native CPU is not necessarily compatible with another.

To build this repo's native benchmark: `zig build bench -Doptimize=ReleaseFast -Dcpu=native -Dnative-kernel=true`.

See [optimization and 8-core/16-thread benchmarks](bench/SCALING.md), including the [original Rust comparison](bench/README.md).
