# ffmpeg

[FFmpeg](https://ffmpeg.org/) — record, convert and stream audio and video. A single self-contained binary, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/ffmpeg/actions/workflows/ffmpeg.yml/badge.svg)](https://github.com/unpins/ffmpeg/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install ffmpeg`.

Ships `ffmpeg` and `ffprobe`. The `ffplay` player is not included.

## Usage

Run the `ffmpeg` program with [unpin](https://github.com/unpins/unpin):

```bash
unpin ffmpeg -i input.mp4 -c:v libx264 -c:a aac output.mkv
```

To install the programs onto your PATH:

```bash
unpin install ffmpeg
```

`unpin install ffmpeg` creates the `ffmpeg` and `ffprobe` commands.

| command   | what it does                                        |
| --------- | --------------------------------------------------- |
| `ffmpeg`  | transcode and process audio / video                 |
| `ffprobe` | inspect a media file's streams, format and metadata |

## Man pages

13 man pages are embedded in the binary: the two programs and FFmpeg's
reference manuals. Read them with `unpin man ffmpeg` (the `ffmpeg` page),
`unpin man ffmpeg ffprobe`, or `unpin man ffmpeg ffmpeg-filters` — likewise
`ffmpeg-codecs`, `ffmpeg-formats`, `ffmpeg-protocols`, `ffmpeg-devices`,
`ffmpeg-bitstream-filters`, `ffmpeg-utils`, `ffmpeg-scaler`,
`ffmpeg-resampler`, and the complete `ffmpeg-all` and `ffprobe-all`.

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

`ffmpeg -buildconf` lists what this build was configured with. Beyond FFmpeg's
built-in codecs, formats and filters:

### On Linux, macOS and Windows

- **Network** — HTTPS and the other TLS protocols (OpenSSL), SRT (libsrt), SFTP
  (libssh), RIST (librist), and RTMP including `rtmps://`, `rtmpe://` and
  `rtmpts://`
- **Video encoders** — libx264 (H.264), libx265 (H.265, 8/10/12-bit), libsvtav1 and libaom (AV1), libvpx (VP8/VP9), libxvid, libtheora
- **Video decoders** — libdav1d (AV1)
- **Audio encoders** — libopus, libvorbis, libmp3lame, libtwolame (MP2), libspeex, libopencore-amrnb
- **Audio decoders** — libopencore-amrwb, libopenmpt (tracker formats: MOD / XM / IT / S3M / MPTM / …), libgme (NES / SNES / Genesis / Game Boy / MSX chiptunes)
- **Audio processing** — libsoxr (resampler), librubberband (time-stretch / pitch-shift), libbs2b (stereo crossfeed), libmysofa (HRTF / `sofalizer`)
- **Images** — libwebp, libopenjpeg (JPEG 2000), librsvg (SVG), zimg (`zscale`)
- **Compression** — zlib, bzip2, lzma, iconv
- **Text and subtitles** — libass, freetype, harfbuzz, fribidi, fontconfig (`subtitles`, `drawtext`)
- **Streaming manifests** — libxml2 (DASH / HLS)
- **Blu-ray** — libbluray
- **Filters** — libqrencode (QR codes), libquirc (QR decoding), libvidstab (stabilization)
- **Teletext** — libzvbi (DVB teletext and VBI)
- **Fingerprints** — the chromaprint muxer (AcoustID)

### Linux only

These rely on Linux kernel interfaces:

- **kmsgrab** — KMS / DRM screen capture via libdrm (needs `CAP_SYS_ADMIN` or DRM master)
- **x11grab** — X11 screen capture via libxcb
- **CD audio** — libcdio + libcdio-paranoia
- **Terminal output** — libcaca (`caca` output device)

## Build notes

- **TLS certificates are not checked by default**, as in upstream FFmpeg. With
  `-tls_verify 1` they are checked against the system's CA certificates on
  Linux and macOS. On Windows, and on a system with none installed, the binary
  uses the Mozilla root certificates built into it. `-ca_file` (or the
  `SSL_CERT_FILE` environment variable) selects another bundle.
- **Not included:** `ffplay`; hardware acceleration (VAAPI, VDPAU, NVENC,
  VideoToolbox, Vulkan), which loads vendor drivers at run time; GnuTLS and
  libsmbclient; and the libjxl, libgsm, openh264, rav1e, kvazaar,
  vvenc, libvmaf, lcms2 and libplacebo integrations.
- **Tests:** FFmpeg's own test suite (FATE) does not run in this build. Every
  build it can run encodes a short clip through libaom, SVT-AV1, libvpx,
  libx264, libx265, libtheora, FFV1, LAME, Opus and Vorbis, and CI runs a
  multi-encoder transcode on each platform it can execute, the Windows `.exe`
  included.
