# ffmpeg

Standalone build of [FFmpeg](https://ffmpeg.org/) — headless, no GUI player.

[![CI](https://github.com/unpins/ffmpeg/actions/workflows/ffmpeg.yml/badge.svg)](https://github.com/unpins/ffmpeg/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

Ships two CLI tools: `ffmpeg` (transcoder) and `ffprobe` (inspector). `ffplay` is intentionally omitted — see [Excluded features](#excluded-features) below.

## Installation

Install with [unpin](https://github.com/unpins/unpin):

```bash
unpin ffmpeg
```

Or run without installing:

```bash
unpin run ffmpeg
```

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
- **Streaming protocols** — SRT (libsrt), SFTP (libssh), RTMP (librtmp, plaintext only — `rtmps://` via ffmpeg-internal mbedtls), RIST (librist)
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

mbedtls everywhere — both for ffmpeg's own `--enable-mbedtls` (HTTPS / TLS in HTTP / RTMPS / HLS) and as the static crypto backend for libsrt and libssh. OpenSSL is intentionally excluded: it would pull the full provider stack (legacy + ML-DSA / SLH-DSA post-quantum) for a few SHA / AES symbols. Net effect on the Linux build: ~5 MB smaller, identical user-facing features.

### Single binary, no companion DLLs

Per the project [dynamic-link-policy](https://github.com/unpins/docs/blob/main/dynamic-link-policy.md), each platform ships exactly one executable (plus `ffprobe`). On Windows this means the GCC runtime (libgcc, libstdc++, libwinpthread, libmcfgthread) is folded into the `.exe` via `-static -static-libgcc -static-libstdc++` plus a pkg-config `Libs.private` rewrite in `nix-lib/mingw-overlay/x265.nix` (x265's CMake probe otherwise embeds a dynamic-libgcc link sequence that every `pkg-config --static` consumer would re-inject). The `--allow-multiple-definition` extra-ldflag is the canonical workaround for `compiler_builtins` colliding between librsvg's Rust staticlib and ffmpeg's own libgcc.

### Excluded features

- **ffplay** — needs SDL2 + a software renderer + audio backend chain; cross-platform static SDL2 isn't part of this build. Tracked as a learning exercise alongside `mpv`.
- **Hardware acceleration** (vaapi, vdpau, nvenc, videotoolbox, vulkan hwaccel) — every backend `dlopen`s a vendor driver at runtime; musl-static can't load glibc-built `.so`s, and Windows / macOS pull the same wall. Unblock requires the planned `libdl-interceptor v2` infrastructure.
- **OpenSSL backends** — see Crypto backend above.
- **libsmbclient, libjxl, libgsm, openh264, libxavs2, libdavs2** — deferred, not yet ported to `pkgsStatic` / `pkgsCross` cleanly.
- **GUI / X11 desktop features on macOS and Windows** — kmsgrab / x11grab / libcaca / libcdio are physically Linux-only (see above).

### Codec set selection

`pkgsStatic.ffmpeg-headless` from nixpkgs is not reused — it pulls openapv / ocl-icd / libtiff / libsndfile, codec deps that break under `pkgsStatic`. This flake ships only the codecs it wants and runs `./configure` itself; see `flake.nix` and `nix-lib/native-overlay/*.nix` for per-dependency rationale.
