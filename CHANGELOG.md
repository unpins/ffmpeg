# Changelog

## [Unreleased]

## [8.1.2-1] - 2026-09-26

### Added

- Builds now verify their own optimized code: on every platform where the build
  can run the binary it produces, each hand-written SIMD routine is checked
  against FFmpeg's portable C version of the same operation, roughly 15 000
  comparisons. Nothing changes for you unless one disagrees, in which case the
  build stops instead of shipping.
- On Linux, hostnames in URLs (`http://`, `rtmp://`, `srt://`, …) now resolve
  on a machine whose DNS resolver is missing or unreachable — Android, or a
  container with no `/etc/resolv.conf` — once you point unpins at a name server.

### Changed

- Updated to FFmpeg 8.1.2.
- TLS (`https://`, `rtmps://`, …) now uses OpenSSL instead of mbedtls.

### Fixed

- `-tls_verify 1` rejected every server, even with a valid certificate, unless
  `-ca_file` was also given: the binary did not read the system's CA
  certificates. It now uses them on Linux and macOS, and the Mozilla root
  certificates built into the binary on Windows and on a system with none
  installed.
- `drawtext` without `fontfile=` failed on macOS and Windows with "Cannot find
  a valid font for the family Sans": the binary only looked for fonts in a
  folder that exists on the machine that built it. When no fontconfig
  configuration is installed it now uses the system's font folders — on
  Windows the system and per-user Fonts folders, on macOS `/System/Library/Fonts`
  and `/Library/Fonts`.
- On Windows, `-c:v libtheora` wrote a broken stream: past the first frame,
  players and decoders reported errors ("error in unpack_block_qpis").
- The Linux ppc64le binary encoded broken video with `-c:v libx264`: a short
  clip came out at a fraction of the quality at four times the size. The
  rebuilt binary encodes it like the other platforms. Measured under emulation.
