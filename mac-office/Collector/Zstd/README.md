The Zstandard v1.5.7 streaming decoder is built into Codex Office for compressed session archives.
These files come from the [upstream v1.5.7 source archive](https://github.com/facebook/zstd/tree/v1.5.7)
(archive SHA-256 `37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3`).

`zstddeclib.c` was generated using the upstream `build/single_file_libs/create_single_file_decoder.sh`.
`zstd.h`, `zstd_errors.h` and `LICENSE` are unmodified copies from that release.
