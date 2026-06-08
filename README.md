# ffmpeg

[FFmpeg](https://ffmpeg.org/) — headless, no GUI player. A single self-contained binary, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/ffmpeg/actions/workflows/ffmpeg.yml/badge.svg)](https://github.com/unpins/ffmpeg/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install ffmpeg`.

Ships `ffmpeg` and `ffprobe`. `ffplay` is intentionally omitted — see [Excluded features](#excluded-features) below.

## Usage

Run the `ffmpeg` program with [unpin](https://github.com/unpins/unpin):

```bash
unpin ffmpeg -i input.mp4 output.mkv
```

To install the programs onto your PATH:

```bash
unpin install ffmpeg
```

`unpin install ffmpeg` creates the `ffmpeg` and `ffprobe` commands.

## Programs

| command   | what it does                                       |
| --------- | -------------------------------------------------- |
| `ffmpeg`  | transcode and process audio / video                |
| `ffprobe` | inspect a media file's streams, format and metadata |

## Build locally

```bash
nix build github:unpins/ffmpeg
./result/bin/ffmpeg -version
```

Or run directly:

```bash
nix run github:unpins/ffmpeg -- -version
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/ffmpeg/releases) page has standalone binaries for manual download.

## Features

`ffmpeg -version` prints the full configure line. The feature matrix below is the source of truth.

### Common to Linux / macOS / Windows

- **TLS / HTTPS** — mbedtls
- **Video encoders** — libx264 (H.264), libx265 (H.265, 8/10/12-bit), libsvtav1 (AV1), libaom (AV1 ref), libvpx (VP8/VP9), libxvid, libtheora
- **Video decoders** — libdav1d (AV1 perf)
- **Audio encoders** — libopus, libvorbis, libmp3lame, libtwolame (MP2), libspeex, libopencore-amrnb
- **Audio decoders** — libopencore-amrwb, libopenmpt (tracker formats: MOD / XM / IT / S3M / MPTM / …)
- **Audio processing** — libsoxr (resampler), librubberband (time-stretch / pitch-shift), libbs2b (Bauer stereo crossfeed), libmysofa (HRTF / SOFAlizer)
- **Image** — libwebp, libopenjpeg (JPEG 2000), librsvg (SVG → raster), zimg (color / scaling)
- **Containers / compression** — zlib, bzip2, lzma, iconv
- **Subtitles / fonts** — libass + freetype + harfbuzz + fribidi + fontconfig
- **Manifests** — libxml2 (DASH / HLS)
- **Streaming protocols** — SRT (libsrt), SFTP (libssh), RTMP (ffmpeg-native, incl. `rtmpe://` / `rtmps://` / `rtmpts://` over mbedtls — no librtmp), RIST (librist)
- **Discs** — libbluray
- **Filters** — libqrencode (QR overlay / source), libquirc (QR decoder), libvidstab (video stabilization)
- **Demuxers** — libgme (NES / SNES / Genesis / GameBoy / MSX chiptune)
- **Captions** — libzvbi (DVB teletext + VBI)
- **Fingerprint** — chromaprint muxer (AcoustID)

### Linux-only

Features that depend on a Linux-specific kernel ABI or socket — physically not portable:

- **kmsgrab** — KMS / DRM screen capture via libdrm (needs `CAP_SYS_ADMIN` or DRM master)
- **x11grab** — X11 screen capture via libxcb (needs only the X server socket)
- **CD audio** — libcdio + libcdio-paranoia (Linux CDDA ioctls)
- **Terminal output** — libcaca (color ASCII-art `caca_outdev`)

## Build notes

### Crypto backend

mbedtls everywhere — ffmpeg's own TLS (`--enable-mbedtls`) and the static crypto backend for libsrt + libssh. OpenSSL is excluded: it drags the full provider stack for a few SHA/AES symbols (~5 MB on Linux, same features).

### Single binary, no companion DLLs

Each platform ships one executable (plus `ffprobe`), per the [dynamic-link-policy](https://github.com/unpins/docs/blob/main/dynamic-link-policy.md). On Windows the GCC runtime (libgcc, libstdc++, libwinpthread, libmcfgthread) is folded into the `.exe`. See `flake.nix` and `nix-lib/mingw-overlay/x265.nix` for the link mechanics.

### Man pages

13 man pages are embedded in the binary — read with `unpin man ffmpeg` (or `ffprobe`, `ffmpeg-filters`, `ffmpeg-codecs`, …). The set is the two programs plus the component reference manuals (`ffmpeg-utils`, `ffmpeg-formats`, `ffmpeg-protocols`, `ffmpeg-devices`, `ffmpeg-bitstream-filters`, `ffmpeg-scaler`, `ffmpeg-resampler`, and the `-all` variants). `ffplay.1` and the `libav*.3` library docs are excluded — we ship the CLI binaries, not ffplay or the libraries.

### Excluded features

- **ffplay** — needs the SDL2 renderer/audio chain; static cross-platform SDL2 isn't in this build. Tracked alongside `mpv`.
- **Hardware acceleration** (vaapi, vdpau, nvenc, videotoolbox, vulkan) — each `dlopen`s a vendor driver; musl-static can't load glibc `.so`s, and Windows/macOS hit the same wall. Needs the planned `libdl-interceptor v2`.
- **OpenSSL backends** — see Crypto backend above.
- **libsmbclient, libjxl, libgsm, openh264, libxavs2, libdavs2** — deferred, not yet clean under `pkgsStatic`/`pkgsCross`.
- **kmsgrab / x11grab / libcaca / libcdio on macOS + Windows** — physically Linux-only (see Linux-only above).

### Codec set selection

nixpkgs' `pkgsStatic.ffmpeg-headless` is not reused (it pulls openapv / ocl-icd / libtiff / libsndfile, which break under `pkgsStatic`). This flake configures its own codec set; see `flake.nix` and `nix-lib/native-overlay/*.nix`.

### Tests

No suite runs: FFmpeg's FATE needs gigabytes of sample media + network. CI instead smoke-runs `ffmpeg -version` on every target (incl. the Windows `.exe`).
