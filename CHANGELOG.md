# Changelog

## [Unreleased]

### Added

- On Linux, hostnames in URLs (`http://`, `rtmp://`, `srt://`, …) now resolve
  on a machine whose DNS resolver is missing or unreachable — Android, or a
  container with no `/etc/resolv.conf` — once you point unpins at a name server.

### Fixed

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
