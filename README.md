# ffmpeg

Standalone build of [FFmpeg](https://ffmpeg.org/) (headless, no GUI). Runs on any Linux, macOS or Windows without external dependencies.

## Installation

You can install this package instantly using the [unpin](https://github.com/unpins/unpin) package manager:

```bash
unpin ffmpeg
```

Or run it without installing:

```bash
unpin run ffmpeg
```

## Build locally

```bash
nix build github:unpins/ffmpeg
./result/bin/ffmpeg -version
```

Or, in one shot:

```bash
nix run github:unpins/ffmpeg
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Features

`ffmpeg -version` shows the full configure line. Across all platforms (Linux, macOS, Windows) the binary ships:

- **Video:** H.264 (libx264), AV1 decode (libdav1d)
- **Audio:** Opus, Vorbis, MP3 (LAME), zimg scaler
- **Container:** zlib, bzip2, lzma, iconv

On **Linux** the binary additionally includes:

- **TLS / HTTPS:** mbedtls
- **Video encoders:** SVT-AV1, x265 (8/10/12-bit), libvpx (VP8/VP9), libxvid, libtheora, libaom
- **Audio encoders:** libtwolame (MP2), libspeex, libopencore-amrnb
- **Audio decoders:** libopencore-amrwb, libmodplug
- **Audio processing:** libsoxr resampler
- **Image:** libwebp, libopenjpeg (JPEG 2000), librsvg (SVG → raster)
- **Subtitles:** libass + freetype + harfbuzz + fribidi + fontconfig
- **Manifests:** libxml2 (DASH / HLS)
- **Streaming protocols:** SRT (libsrt), SFTP (libssh), RTMP/RTMPS (librtmp + ffmpeg-internal mbedtls), RIST (librist)
- **Discs:** libbluray
- **Filters:** libqrencode (QR code overlay / source), libvidstab (video stabilization), librubberband (audio time-stretch / pitch-shift)
- **Demuxers:** libgme (NES / SNES / Genesis / GameBoy / MSX chiptune), libcdio (audio CD / CDDA grabbing via libcdio-paranoia)
- **Captions:** libzvbi (DVB teletext + VBI closed captions)
- **Fingerprint:** chromaprint muxer (AcoustID-compatible audio fingerprint)
- **Output devices:** libcaca (color ASCII-art terminal output)
- **Capture:** kmsgrab (KMS screen capture via libdrm — needs CAP_SYS_ADMIN or DRM master), x11grab (X11 screen capture via libxcb — needs only X server socket access)

The smaller macOS / Windows feature set keeps the package working on the cross-platform pkgsStatic toolchain that powers this build. Extending the extras across all targets is tracked separately.

## Manual Download

Standalone binaries are available on the [Releases](https://github.com/unpins/ffmpeg/releases) page.
