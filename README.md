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

## Manual Download

Standalone binaries are available on the [Releases](https://github.com/unpins/ffmpeg/releases) page.
