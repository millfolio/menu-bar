# CZstd

Vendored **decompression-only** amalgamation of [zstd](https://github.com/facebook/zstd)
(BSD-3-Clause, see `LICENSE`), statically linked into the app so we never depend
on a system `zstd` binary or `libzstd.dylib` — macOS ships neither, and the Mojo
toolchain we download arrives as `.conda` packages whose payloads are
`*.tar.zst`. This mirrors how `pixi`/`rattler` statically link libzstd.

Files:
- `zstddeclib.c` — generated from zstd **v1.5.6** via
  `build/single_file_libs/create_single_file_decoder.sh` (decoder only; no
  compressor, so it's ~0.9 MB of source).
- `include/zstd.h` — the public API header (zstd v1.5.6), exposed as the `CZstd`
  module.

To update: regenerate `zstddeclib.c` and copy `lib/zstd.h` from a new zstd
release tag, then bump the version here.
