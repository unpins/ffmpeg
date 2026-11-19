{
  description = "FFmpeg (headless) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;
    in
    ulib.mkStandaloneFlake {
      inherit self;
      dnsFallback = true; # resolves hostnames; opt into the Android DNS fallback
      name = "ffmpeg";
      # Built with --enable-gpl --enable-version3; nixpkgs' ffmpeg meta tracks
      # its own withGPL arg, not our configure flags, so set the effective
      # license explicitly. (Custom build → no upstream meta.license to carry.)
      license = "GPL-3.0-or-later";
      # Custom mkDerivation → no upstream meta.description to carry either.
      description = "Record, convert and stream audio and video (ffmpeg + ffprobe)";

      # No winManRoot: the mingw windows .exe builds + installs the same 13
      # curated man pages as native (the installPhase `make`s doc/*.1 via
      # build-host perl on every target), so it harvests its OWN man — exactly
      # the pages native/darwin embed, no nixpkgs graft.

      # Execute the built binary in CI (esp. windows-x86_64, which only
      # runs here). TRANSCODE, don't just print: `-version` never opens a file,
      # a device or a terminal, so it stayed green through a fold that had
      # replaced libc's `ioctl` with a NULL pointer (zvbi's LD_PRELOAD shim —
      # see nix-lib/native-overlay/zvbi.nix) and segfaulted on every real run.
      # A synthetic source through lavfi into the null muxer needs no input
      # file and writes no output, so it works identically on every runner,
      # while exercising demux → decode → filter → encode → mux. The summary
      # line only prints once every output finished.
      #
      # The null muxer's default encoder is a passthrough, which is how a
      # binary whose libaom-av1 and ffv1 segfaulted (thread stack) and whose
      # libtheora crashed on windows (inlined asm) passed this smoke. So the
      # same input also goes through those real encoders, one output each; the
      # installCheck covers the same list, plus i686, one encoder at a time.
      smoke = [
        "-hide_banner" "-nostdin"
        "-f" "lavfi" "-i" "testsrc2=size=64x64:rate=25:duration=0.4"
        "-f" "lavfi" "-i" "sine=duration=0.4"
        "-map" "0:v" "-c:v" "ffv1" "-f" "null" "-"
        "-map" "0:v" "-c:v" "libaom-av1" "-cpu-used" "8" "-f" "null" "-"
        "-map" "0:v" "-c:v" "libtheora" "-f" "null" "-"
        "-map" "0:v" "-c:v" "libx265" "-f" "null" "-"
        "-map" "1:a" "-c:a" "libmp3lame" "-f" "null" "-"
      ];
      smokePattern = "video:[0-9]+KiB";

      # Build via the unpin-llvm engine + bitcode self-fold. ffmpeg installs
      # two mains (ffmpeg + ffprobe) that share the whole libav* code; the
      # engine folds them into one `ffmpeg` dispatcher with `ffprobe` as an
      # argv[0] alias. requires.cxx: x265/svt-av1/aom/libwebp/libopenmpt/
      # harfbuzz/chromaprint/librsvg drag libc++ into the closure.
      engine = "unpin-llvm";
      multicall = {
        windows = true;
        requires.cxx = true;
        # darwin: the frameworks the folded binary links, derived in nix-lib
        # (ffmpeg.nix, `darwinFrameworks`).
        requires.frameworks = ulib.unpinFfmpeg.darwinFrameworks;
        removeReferences = ulib.unpinFfmpeg.deadRefs;
        depArchives = ulib.unpinFfmpeg.depArchives;
        programs = [
          { name = "ffmpeg"; }
          { name = "ffprobe"; }
        ];
        # ffmpeg + ffprobe share the entire libav* codebase; fold those private
        # archives ONCE (not per-program) so libavcodec's module-level inline asm
        # — e.g. mlpdsp's `.global ff_mlp_firorder_N` — isn't duplicated across
        # the two modules (which the mega-link's integrated assembler rejects).
        foldSharedArchives = true;
      };

      # The FFmpeg build itself lives in nix-lib (ffmpeg.nix), shared with
      # fpcalc.
      #
      # The bitcode self-fold reaches here too (multicall.windows = true), so the
      # same `ffmpeg` dispatcher with `ffprobe` as an argv[0] alias is built from
      # the captured module rather than by the hand-rolled cpp-rename recompile
      # that used to live in ./multicall.nix. `binName` is itself an applet, so
      # nix-lib picks `ffmpeg` as the bare-invocation default on both halves —
      # which is what kept the released `ffmpeg-<ver>-x86_64-windows.exe` (a stem
      # matching no applet) from printing a usage listing.
      build = origPkgs: ulib.unpinFfmpeg.native origPkgs;
      windowsBuild = pkgs: ulib.unpinFfmpeg.windows pkgs;
    };
}
