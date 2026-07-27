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

      # Man pages we actually ship: the two CLI tools (ffmpeg/ffprobe) plus
      # the component reference manuals. Deliberately EXCLUDES ffplay.1 /
      # ffplay-all.1 (we --disable-ffplay) and libav*.3 (library API docs that
      # need doxygen; we ship the CLI binaries, not the libraries). EVERY build
      # — native, cross-linux, AND the mingw windows .exe — generates this set
      # in-place in its installPhase (texi2pod.pl + pod2man run on the build
      # host, no target execution) and installs it to $out/share/man, so each
      # binary harvests its OWN man via withMan. man is reproducible roff, so
      # all platforms stay byte-identical. No graft, no separate man derivation.
      usefulMan = [
        "ffmpeg" "ffmpeg-all" "ffprobe" "ffprobe-all"
        "ffmpeg-utils" "ffmpeg-scaler" "ffmpeg-resampler"
        "ffmpeg-codecs" "ffmpeg-bitstream-filters" "ffmpeg-formats"
        "ffmpeg-protocols" "ffmpeg-devices" "ffmpeg-filters"
      ];

      # nixpkgs's pkgsStatic.ffmpeg-headless pulls openapv/ocl-icd/
      # libtiff/libsndfile etc — codec deps that break under pkgsStatic.
      # We ship only the codecs we want and run configure ourselves.
      mkFfmpeg = pkgs:
        { extraConfigureFlags ? [ ]
        , extraInputs ? [ ]
        }:
        let
          stdenv = pkgs.stdenv;
          isMinGW = stdenv.hostPlatform.isMinGW or false;
          isDarwin = stdenv.hostPlatform.isDarwin;
          # unpin-llvm engine active on this scope (linux + darwin, not mingw).
          isEngine = pkgs.lib.hasInfix "unpin-cc" (stdenv.cc.name or "");
          targetOs =
            if isMinGW then "mingw64"
            else if isDarwin then "darwin"
            else "linux";
          exe = if isMinGW then ".exe" else "";
          flags = [
            "--prefix=$out"
            "--cross-prefix=${stdenv.hostPlatform.config}-"
            # ffmpeg's cc_default="gcc" / cxx_default="g++" — appended
            # after cross-prefix this gives `arm64-apple-darwin-gcc` /
            # `…-g++`, neither of which exists on darwin (clang backend).
            # nixos-26.05's clang-21 cc-wrapper for the prefixed darwin
            # toolchain dropped the `-g++` alias too, so the final
            # LDXX link of ffmpeg_g/ffprobe_g died with
            # `x86_64-apple-darwin-g++: command not found`. Force the
            # `-cc`/`-c++` wrapper symlinks, which exist across both the
            # clang and gcc nixpkgs cc-wrappers on every target.
            "--cc=${stdenv.hostPlatform.config}-cc"
            "--cxx=${stdenv.hostPlatform.config}-c++"
            "--host-cc=${pkgs.buildPackages.stdenv.cc}/bin/cc"
            # Hard-reference the cross pkg-config wrapper. Splicing in
            # nativeBuildInputs picks the BUILD-platform wrapper (named
            # after build triple), and ffmpeg's auto-derive (cross_prefix
            # + "pkg-config") expects a HOST-triple binary — match never
            # happens, pkg_config silently becomes "false", every probe
            # returns "not found". `pkgsBuildHost.pkg-config` (default,
            # pre-splicing) IS the host-triple wrapper; reference it by
            # explicit /bin path to bypass the splicing rewrite.
            "--pkg-config=${pkgs.pkgsBuildHost.pkg-config}/bin/${stdenv.hostPlatform.config}-pkg-config"
            "--enable-cross-compile"
            "--target-os=${targetOs}"
            "--arch=${stdenv.hostPlatform.uname.processor}"
            # ffmpeg's configure auto-derives pkg-config as
            # `${cross_prefix}pkg-config` — the binary the wrapper
            # actually ships. Don't pass `--pkg-config=pkg-config`
            # or it looks for a bare `pkg-config` that isn't in PATH.
            "--pkg-config-flags=--static"
            # Build the curated man set in-place: each target generates its own
            # 13 pages. A single x86_64-linux `ffmpegMan` CAN'T be realized on
            # the darwin / aarch64 / armv7l CI runners (no x86_64-linux builder),
            # so the man must come from the per-arch build. man is reproducible
            # roff (pod2man `--date=" "`), so it stays byte-identical across
            # platforms. Skip html/txt/pod; `ffmpegMan` feeds only the windows
            # mingw cross via winManRoot (that runner IS x86_64-linux).
            "--disable-htmlpages" "--disable-txtpages" "--disable-podpages"
            "--disable-debug" "--disable-stripping"
            "--enable-gpl" "--enable-version3"
            "--enable-runtime-cpudetect" "--enable-network"
            "--disable-ffplay" "--enable-ffmpeg" "--enable-ffprobe"
            "--enable-zlib" "--enable-bzlib" "--enable-lzma" "--enable-iconv"
            "--enable-libx264" "--enable-libdav1d" "--enable-libopus"
            "--enable-libvorbis" "--enable-libmp3lame" "--enable-libzimg"
          ]
          # darwin can't take any "-static" linker flag (Apple ships
          # only libSystem.dylib — no libSystem.a, so the compiler probe
          # `cc -static main.c` aborts configure). On darwin we rely on
          # ld picking the dep .a's by preference and let libSystem stay
          # implicit-dynamic per docs/dynamic-link-policy.md. ffmpeg
          # reinterprets `--enable-static --disable-shared` as
          # LDFLAGS=-static internally (same trap that hit htop / tmux),
          # so omit those too on darwin.
          #
          # The C++ codec deps drag in libc++ two ways, both of which
          # default to the dynamic /usr/lib/libc++.1.dylib that the
          # portability allowlist rejects (libc++ must be folded in
          # statically):
          #   - dep `.pc` `Libs.private` under `--pkg-config-flags=--static`
          #     (libgme `-lstdc++`, chromaprint `-lc++`, …);
          #   - ffmpeg's own hardcoded `-lstdc++` in the libgme/libopenmpt/
          #     librubberband/libsnappy `require` probes.
          # We can't suppress those tokens (they come from many sources and
          # also gate configure's lib-detection link tests), so instead we
          # make them *resolve static*: configurePhase drops a `-L` shim
          # exposing libc++.a as both `libc++.a` and `libstdc++.a` (and
          # `libc++abi.a`) ahead of the dylib dirs, and we pass
          # `-Wl,-search_paths_first` on the final link so ld64 takes the
          # `.a` from the shim dir instead of falling back to its default
          # `-search_dylibs_first` (which finds libc++.1.dylib first). That
          # makes every `-lc++`/`-lstdc++`/`-lc++abi` link static. ffmpeg
          # links via the C driver, so there's no implicit `-lc++` to worry
          # about. See docs/dynamic-link-policy.md. (libSystem stays
          # implicit-dynamic.)
          ++ (if isDarwin then [
                "--extra-ldflags=-Wl,-search_paths_first"
                # See the linux `-lstdc++` note below: srt.pc (and other C++ deps
                # found via require_pkg_config) omit the C++ runtime, so force it.
                "--extra-libs=-lstdc++"
                "--extra-libs=-lc++abi"
              ]
              else if isMinGW then [
                # mingw single-binary policy: fold the toolchain runtime
                # (libgcc, libstdc++, libwinpthread, libmcfgthread) into
                # the .exe so we ship only `ffmpeg.exe` / `ffprobe.exe`,
                # no DLLs next to them. `mingwStaticCross` covers USER
                # libs (rewrites cc-wrapper to prefer `.a`), but the GCC
                # driver still defaults to dynamic-libgcc/libstdc++.
                #
                # - `-static`: pick `.a` over `.dll.a` everywhere.
                # - `-static-libgcc`: emit `-lgcc -lgcc_eh` instead of
                #   `-lgcc_s -lgcc` from gcc's link spec.
                # - `-static-libstdc++`: needed because x265/svt-av1/aom/
                #   libwebp/libopenmpt/harfbuzz/chromaprint bring C++.
                #
                # Two gotchas required nix-lib companion overlays
                # (`mingw-overlay/x265.nix` and the rust+mingw line
                # below):
                #
                # 1. x265's CMake probes the toolchain for "what does
                #    C++ EH need" and embeds the result in `x265.pc`'s
                #    `Libs.private` — captured WITHOUT `-static-libgcc`,
                #    so it bakes in `-lgcc_s ... -lgcc_s ...`. Every
                #    `pkg-config --static x265 --libs` consumer
                #    (ffmpeg's link) then re-injects `-lgcc_s` and the
                #    linker prefers libgcc_s.dll.a (the .dll import
                #    lib) over libgcc_eh.a. The overlay rewrites
                #    `Libs.private` to the static-libgcc form.
                #
                # 2. `--allow-multiple-definition` is the canonical
                #    rust + mingw cross workaround for librsvg-2.a
                #    (rust) bundling `compiler_builtins` symbols
                #    (`___chkstk_ms`, `__udivmodti4`, `__udivti3`)
                #    that ffmpeg's own libgcc link adds again — the
                #    COMDAT/weak marking doesn't survive the
                #    dual-static-archive link path.
                "--enable-static" "--disable-shared"
                "--extra-ldflags=-static"
                "--extra-ldflags=-static-libgcc"
                "--extra-ldflags=-static-libstdc++"
                "--extra-ldflags=-Wl,--allow-multiple-definition"
              ]
              else [ "--extra-ldflags=-static" "--enable-static" "--disable-shared" ]
                # Engine linux: force the whole static C++ runtime onto every link.
                # C++ codec deps split two ways: some ffmpeg detects with a
                # hardcoded `-lstdc++` (libgme…), but others (srt) come via
                # `require_pkg_config` and their `.pc` omits the C++ runtime
                # entirely (srt.pc: `Libs.private: -lmbedtls …`, no `-lstdc++`), so
                # every `std::__1::…` from srt.a is undefined. Append `-lstdc++`
                # (→ libc++.a via the cxx-static shim) plus its `__cxa_*`/typeinfo
                # (libc++abi) and `_Unwind_*` (LLVM libunwind), in dependency order.
                # On a C-only dep's link these static archives simply aren't pulled.
                ++ pkgs.lib.optionals isEngine [
                  "--extra-libs=-lstdc++"
                  "--extra-libs=-lc++abi"
                  "--extra-libs=-lunwind"
                ]
                # armv7l only: the sysroot's `libunwind.a` is NATIVE while every
                # dep and musl itself are bitcode. On ARM, LTO codegen emits the
                # EHABI `_Unwind_Resume` calls that any cleanup needs, so nothing
                # references libunwind until AFTER the LTO step — and a member
                # pulled that late brings undefined `fprintf`/`snprintf`/`stderr`/
                # `abort`/`__assert_fail` that the bitcode libc can no longer
                # satisfy, LTO having already chosen its members. (`-lc` appended
                # afterwards does not help, for the same reason.) It surfaces as a
                # bogus `fontconfig not found using pkg-config` — fontconfig is
                # simply the first configure probe with enough bitcode behind it to
                # emit a cleanup. Forcing the symbol undefined from the start pulls
                # libunwind in the pre-LTO archive pass instead, so its libc needs
                # are visible while LTO still has the whole bitcode libc to draw
                # from. Same class as the i686 `-Wl,-u,malloc` in the musl-bitcode
                # work; one symbol is enough because the rest ride in with it.
                ++ pkgs.lib.optional
                  (isEngine && pkgs.stdenv.hostPlatform.isAarch32)
                  "--extra-ldflags=-Wl,-u,_Unwind_Resume")
          ++ extraConfigureFlags;
        in
        stdenv.mkDerivation ({
          pname = "ffmpeg";
          inherit (pkgs.ffmpeg-headless) version src;

          # engine: make ffmpeg's inline-asm probes ASSEMBLE.
          #
          # `check_inline_asm` decides whether an instruction can be used
          # UNCONDITIONALLY (ffmpeg's own words) by compiling
          # `__asm__ volatile("<insn>")` with $CC -c. Under the engine every
          # compile carries `-flto`, so the object is bitcode and the asm text is
          # merely carried along — nothing assembles, every probe passes. On
          # armv7l that turns HAVE_NEON_INLINE on for a target whose baseline is
          # vfpv3-d16, and the NEON in libavcodec/arm/aac.h (used with no runtime
          # check) only blows up at the LTO link, where the assembler finally runs:
          # `ld-temp.o <inline asm>: vmul.f32 d0, d0, d1 — instruction requires:
          # NEON`. The engine cc already drops `-flto` from anything that looks
          # like a probe, but it recognises them by autoconf's `conftest` filename
          # and ffmpeg names its own `ffconf.*`; the marker define opts these
          # probes into that same escape hatch. Only `_inline` detection changes —
          # `check_as`/`neon_external` already assemble for real, so the runtime-
          # detected NEON in the .S files stays.
          postPatch =
            pkgs.lib.optionalString isEngine ''
              substituteInPlace configure \
                --replace-fail 'test_cc "$@" <<EOF && enable $name' \
                               'test_cc -DUNPIN_conftest=1 "$@" <<EOF && enable $name'
            ''
            # riscv64: musl's <bits/syscall.h> predates the riscv_hwprobe syscall
            # (Linux 6.4), but the cross kernel headers ship <asm/hwprobe.h>.
            # ffmpeg's libavutil/riscv/cpu.c then includes the struct and calls
            # syscall(__NR_riscv_hwprobe, ...) with the number undefined →
            # "'__NR_riscv_hwprobe' undeclared". Define the canonical riscv value
            # (258) when the libc headers lack it, after the real include so a
            # newer musl still wins. Keeps --enable-runtime-cpudetect's
            # V-extension probe working.
            + pkgs.lib.optionalString (stdenv.hostPlatform.isRiscV or false) ''
              sed -i 's|#include <sys/syscall.h>|#include <sys/syscall.h>\n#ifndef __NR_riscv_hwprobe\n#define __NR_riscv_hwprobe 258\n#endif|' libavutil/riscv/cpu.c
            ''
            ;

          # pkgsBuildHost is the canonical "build tools that target host"
          # scope:
          #   linux x86_64-linux native → x86_64-unknown-linux-musl-pkg-config
          #   mingw cross            → x86_64-w64-mingw32-pkg-config
          #   darwin x86_64-darwin cross from arm64-darwin
          #                          → x86_64-apple-darwin-pkg-config
          # ffmpeg's --cross-prefix=<triple>- derives a `<triple>-pkg-config`
          # binary that has to be on PATH; pkgsBuildHost.pkg-config is named
          # to match. `pkgs.buildPackages` picks the BUILD platform's wrapper
          # (wrong triple), and `pkgs.X` with no scope is static + unprefixed.
          # Also: pkgsBuildHost.perl is non-static (build-time tool) — `pkgs`
          # in cross-darwin-pkgsStatic gives perl-static which fails to build.
          nativeBuildInputs = with pkgs.pkgsBuildHost; [ pkg-config nasm yasm perl ];
          # libopus + dav1d carry darwin-aarch64 meson `cpu_family =
          # 'arm64'` fixes; on darwin they come patched from the
          # pkgsStatic overlay below (so transitive consumers — e.g.
          # libsndfile → libopus — see the same patched build), vanilla
          # elsewhere.
          buildInputs = (with pkgs; [
            zlib bzip2 xz libiconv x264 libvorbis libogg lame zimg
            libopus dav1d
          ]) ++ extraInputs;

          strictDeps = true;
          enableParallelBuilding = true;
          stripAllList = [ "bin" ];

          # ffmpeg links each program as `<prog>_g` (its debug binary) then
          # copies it to `<prog>`. The engine's link-capture sidecar is keyed by
          # the LINKED output name, so it lands as `<prog>_g.link`, but the
          # multicall module hook (appended to this postBuild) reads `<prog>.link`
          # → `no link sidecar for ffmpeg`. Alias the sidecars to the program
          # names. Engine-only (`$UNPIN_LINK_DIR` is unset off-engine).
          postBuild = pkgs.lib.optionalString isEngine ''
            for p in ffmpeg ffprobe; do
              [ -f "$UNPIN_LINK_DIR/''${p}_g.link" ] \
                && cp "$UNPIN_LINK_DIR/''${p}_g.link" "$UNPIN_LINK_DIR/$p.link" || true
            done
          '';

          configurePhase = ''
            runHook preConfigure
            ${pkgs.lib.optionalString isEngine ''
              # The engine's C++ runtime is libc++, but ffmpeg's configure probes
              # (libgme/libopenmpt/librubberband/libsnappy `require`) and several
              # dep `.pc` `Libs.private` hardcode `-lstdc++` (and `-lc++`/
              # `-lc++abi`). With no `libstdc++.a` on the search path the libgme
              # probe fails → `ERROR: libgme not found`. Expose the static libc++
              # under all three names ahead of the default dirs so every such
              # token links the engine's static libc++.
              mkdir -p "$TMPDIR/cxx-static"
              ${if isDarwin then ''
                # darwin: the Itanium unwinder is in libSystem, so libc++/libc++abi
                # suffice. ld64 also needs `-Wl,-search_paths_first` (added above)
                # to prefer the `.a` over /usr/lib/libc++.1.dylib.
                ln -sf ${pkgs.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libc++.a"
                ln -sf ${pkgs.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libstdc++.a"
                ln -sf ${pkgs.libcxx}/lib/libc++abi.a "$TMPDIR/cxx-static/libc++abi.a"
              '' else ''
                # linux: use the COMPLETE upstream static libc++/libc++abi from
                # nixpkgs (the engine sysroot's on-demand `cxx/lib/libc++.a` is a
                # re-archived subset — enough for libgme but missing the locale/
                # iostream/random_device members srt's C++ pulls). Their `_Unwind_*`
                # unwinder, though, lives ONLY in LLVM libunwind: nixpkgs `libunwind`
                # is nongnu (lacks them) and `llvmPackages.libunwind` is an empty
                # stub, so take libunwind.a from the sysroot `cxx/lib` (the exact one
                # clang++ links), seeded into the cache by the setup hook that
                # `runHook preConfigure` just fired. `-lc++abi`/`-lunwind` in
                # `--extra-libs` resolve here.
                cxxlib=$(dirname "$(find "$XDG_CACHE_HOME/unpin-llvm" -path '*/cxx/lib/libunwind.a' 2>/dev/null | head -1)")
                test -n "$cxxlib" || { echo "engine cxx sysroot not seeded"; exit 1; }
                ln -sf ${pkgs.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libc++.a"
                ln -sf ${pkgs.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libstdc++.a"
                ln -sf ${pkgs.libcxx}/lib/libc++abi.a "$TMPDIR/cxx-static/libc++abi.a"
                ln -sf "$cxxlib/libunwind.a"          "$TMPDIR/cxx-static/libunwind.a"
              ''}
              export NIX_LDFLAGS="-L$TMPDIR/cxx-static $NIX_LDFLAGS"
            ''}
            # ffmpeg's `require_cpp_condition` for x264 trips on the
            # default x264.h header decoration; drop the check.
            sed -i '/X264_API_IMPORTS/d' configure
            ./configure ${builtins.concatStringsSep " " flags}
            ${pkgs.lib.optionalString (stdenv.hostPlatform.isPower64 or false) ''
              # `maclhw`/`mullhw` (libavcodec/ppc/mathops.h `#if HAVE_PPC4XX`) are
              # 32-bit PPC-4xx/BookE MAC instructions absent on any 64-bit PowerPC.
              # configure's `check_inline_asm ppc4xx` compiles a `maclhw` snippet
              # to set HAVE_PPC4XX, but under the engine's `-flto` clang defers
              # inline-asm assembly to link time → the probe is a false positive and
              # `enable`s ppc4xx even over `--disable-ppc4xx`. Force HAVE_PPC4XX off
              # in the generated config.h (what mathops.h reads), else the invalid
              # instruction only detonates at the LTO fold-link.
              sed -i 's/#define HAVE_PPC4XX 1/#define HAVE_PPC4XX 0/' config.h
            ''}
            runHook postConfigure
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/share/man/man1
            cp ffmpeg${exe} ffprobe${exe} $out/bin/
            # Curated man set, generated by THIS build (see the configure note):
            # build the 13 pages and install exactly them. native/darwin withMan
            # harvests $out/share/man; windows reads the matching ffmpegMan via
            # winManRoot. man is reproducible, so the sets are byte-identical.
            make ${builtins.concatStringsSep " " (map (m: "doc/${m}.1") usefulMan)}
            cp ${builtins.concatStringsSep " " (map (m: "doc/${m}.1") usefulMan)} \
              $out/share/man/man1/
            runHook postInstall
          '';

          passthru = { pname = "ffmpeg"; inherit (pkgs.ffmpeg-headless) version; };
        });
      # `mkExtras` returns the cross-platform set of feature flags and
      # build inputs that ride on `sharedExtras`. Parameterised on a
      # `pkgsStatic`-like scope so the same registry of fixes applies
      # uniformly to linux, darwin, and mingw — each `nativeFixes.X` is
      # platform-aware (no-op on platforms where the upstream is already
      # fine).
      mkExtras = pkgsStaticScope:
        let
          isEngineScope = pkgsStaticScope.lib.hasInfix "unpin-cc"
            (pkgsStaticScope.stdenv.cc.name or "");
          # Direct (no-feature-disable) fixes pulled in from nix-lib's
          # native-overlay. See `nix-lib/native-overlay/<pkg>.nix` for
          # the per-package rationale.
          svtAv1NoLto    = ulib.nativeFixes.svt-av1        pkgsStaticScope;
          x265Static     = ulib.nativeFixes.x265           pkgsStaticScope;
          xvidStatic     = ulib.nativeFixes.xvidcore       pkgsStaticScope;
          gmeStatic      = ulib.nativeFixes.game-music-emu pkgsStaticScope;
          # librsvg (Rust) can't be an engine derivation — rustc's configureFlags
          # need the cc's libc, which the engine wrapper nulls out. On the engine
          # scopes (linux/darwin) nix-lib injects a PRISTINE, already-fixed librsvg
          # into `pkgsStatic.librsvg`, folded as a native sidecar; use it directly.
          # mingw isn't an engine scope, so apply the fix normally there (it also
          # carries the mingw-only `-lshell32` rustflag).
          librsvgStatic  = if pkgsStaticScope.stdenv.hostPlatform.isMinGW or false
                           then ulib.nativeFixes.librsvg pkgsStaticScope
                           else pkgsStaticScope.librsvg;
          libvpxPkg      = ulib.nativeFixes.libvpx         pkgsStaticScope;
          quircStatic    = ulib.nativeFixes.quirc          pkgsStaticScope;
          # Feature-disable fixes that the user signed off on (the
          # rationale lives in each fix file). srt/libssh swap crypto
          # to mbedtls; rubberband drops
          # side-target plugins; librist/qrencode skip broken tests;
          # libopenmpt + mpg123 drop CLI audio backends; soxr drops
          # openmp; libbluray renames `dec_init` + (darwin) drops
          # fontconfig.
          soxrNoOmp       = ulib.nativeFixes.soxr       pkgsStaticScope;
          srtMbed         = ulib.nativeFixes.srt        pkgsStaticScope;
          libsshMbed      = ulib.nativeFixes.libssh     pkgsStaticScope;
          libristNoTest   = ulib.nativeFixes.librist    pkgsStaticScope;
          qrencodeNoCheck = ulib.nativeFixes.qrencode   pkgsStaticScope;
          rubberbandLean  = ulib.nativeFixes.rubberband pkgsStaticScope;
          libbluraySafe   = ulib.nativeFixes.libbluray  pkgsStaticScope;
          libopenmptLean  = ulib.nativeFixes.libopenmpt pkgsStaticScope;
          chromaprintLean = ulib.nativeFixes.chromaprint pkgsStaticScope;
          # fftw (pulled transitively by rubberband/speex/speexdsp) is fixed
          # via the pkgsStatic overlay in `build` below, not as a direct
          # input — ffmpeg has no fftw feature of its own.
          vidStabPkg      = ulib.nativeFixes.vid-stab   pkgsStaticScope;
          speexdspPkg     = ulib.nativeFixes.speexdsp   pkgsStaticScope;
          speexPkg        = ulib.nativeFixes.speex      pkgsStaticScope;
        in {
          flags = [
            "--enable-mbedtls"
            "--enable-libsvtav1"
            "--enable-libx265"
            "--enable-libwebp"
            "--enable-libvpx"
            "--enable-libsoxr"
            "--enable-libtheora"
            "--enable-libsrt"
            "--enable-libaom"
            "--enable-libopenjpeg"
            "--enable-libxml2"
            "--enable-libxvid"
            "--enable-libopenmpt"
            "--enable-libtwolame"
            "--enable-libspeex"
            "--enable-libssh"
            "--enable-libbluray"
            # No --enable-librtmp on purpose: it conflicts-out ffmpeg's native
            # rtmp/rtmpe/rtmps protocols (configure: rtmp_protocol_conflict /
            # ffrtmpcrypt_protocol_conflict = librtmp_protocol). The native impl
            # does rtmpe:// / rtmps:// / rtmpts:// via the mbedtls we already
            # enable (rtmpdh.c CONFIG_MBEDTLS), so librtmp would only ADD a dep
            # and SUBTRACT working crypto. rtmpdump-the-CLI ships separately.
            "--enable-librist"
            "--enable-libqrencode"
            "--enable-libopencore-amrnb"
            "--enable-libopencore-amrwb"
            "--enable-libvidstab"
            "--enable-librubberband"
            "--enable-chromaprint"
            "--enable-libzvbi"
            "--enable-libgme"
            "--enable-libquirc"
            "--enable-libbs2b"
            "--enable-libmysofa"
            "--enable-libfreetype"
            "--enable-libfribidi"
            "--enable-librsvg"
            "--enable-libass"
            "--enable-libharfbuzz"
            "--enable-libfontconfig"
          ];
          inputs = with pkgsStaticScope; [
            mbedtls
            libwebp
          ] ++ [ libvpxPkg libvpxPkg.dev ] ++ (with pkgsStaticScope; [
            libtheora    libtheora.dev
            libaom       libaom.dev
            openjpeg     openjpeg.dev
            libxml2      libxml2.dev
            libbs2b
            libmysofa    libmysofa.dev
            twolame
            opencore-amr
            zvbi         zvbi.dev
          ]) ++ [ svtAv1NoLto x265Static x265Static.dev soxrNoOmp soxrNoOmp.dev srtMbed xvidStatic libsshMbed libsshMbed.dev libbluraySafe libristNoTest qrencodeNoCheck qrencodeNoCheck.dev rubberbandLean chromaprintLean gmeStatic libopenmptLean libopenmptLean.dev quircStatic speexPkg speexPkg.dev vidStabPkg ]
            ++ (with pkgsStaticScope; [
              freetype  freetype.dev
              fribidi   fribidi.dev
              libass    libass.dev
              harfbuzz  harfbuzz.dev
              fontconfig fontconfig.dev
            ])
            ++ [ librsvgStatic librsvgStatic.dev ]
            # nongnu libunwind was added only to satisfy the `-lunwind` rustc
            # reports for musl Rust (librsvg). On the ENGINE that token is
            # already served by LLVM libunwind (`--extra-libs=-lunwind` → the
            # sysroot cxx/lib unwinder), so pulling nongnu libunwind too is
            # redundant — and on i686 harmful: its 32-bit `_Unwind_Resume`
            # (x86/Gos-linux.c) resumes via libc `setcontext`, absent in
            # musl-i686, so folding its bitcode leaves setcontext undefined
            # (x86_64 links because libunwind ships its own setcontext.S).
            # Engine (all linux + darwin) → drop it; only off-engine would need
            # it, and the sole off-engine target is mingw (SEH, excluded anyway).
            ++ (if isEngineScope || (pkgsStaticScope.stdenv.hostPlatform.isMinGW or false)
                then [ ]
                else [ pkgsStaticScope.libunwind ]);
        };
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
      # line only prints once the mux actually finished.
      smoke = [
        "-hide_banner"
        "-f" "lavfi" "-i" "testsrc=size=64x48:rate=25"
        "-t" "0.2"
        "-f" "null" "-"
      ];
      smokePattern = "video:[0-9]+KiB";

      # Build via the unpin-llvm engine + bitcode self-fold. ffmpeg installs
      # two mains (ffmpeg + ffprobe) that share the whole libav* code; the
      # engine folds them into one `ffmpeg` dispatcher with `ffprobe` as an
      # argv[0] alias. requires.cxx: x265/svt-av1/aom/libwebp/libopenmpt/
      # harfbuzz/chromaprint/librsvg drag libc++ into the closure.
      engine = "unpin-llvm";
      multicall = {
        requires.cxx = true;
        # darwin: the mega relinks from bitcode, so it must name the frameworks
        # itself — nothing propagates here from ffmpeg-static's buildInputs, and
        # ffmpeg's configure never recorded them as flags (the link line the hook
        # captures holds archives only). Derived, not guessed: take the undefined
        # symbols of module.bc + module_native.a AND of every auto-derived dep
        # archive, subtract what all of those plus libSystem define, and map the
        # remainder against the SDK's .tbd exports. Scanning only the module is a
        # LOWER BOUND — the mega globs `lib/*.a` across the closure, so a pulled
        # archive's own references count too (that is what Accelerate and
        # DiskArbitration turned out to be). What survives this list is 16 symbols,
        # all explained: `__dso_handle` comes from the linker, and the
        # `ff_mlp_{fir,iir}order_*` are ffmpeg's own module-level inline asm, absent
        # from the IR symbol table and materialized only at codegen.
        #
        # Four groups: ffmpeg's own darwin backends (VideoToolbox/CoreMedia/
        # CoreVideo, AudioToolbox/CoreAudio, AVFoundation for the avfoundation
        # indev, OpenGL, Accelerate for vDSP's FFT); the text-rendering chain via
        # librsvg → pango → cairo (CoreText/CoreGraphics/ImageIO); glib's gio, which
        # reaches the macOS type and handler database (CoreServices), enumerates
        # mounts through DiskArbitration, and posts notifications through
        # Foundation/AppKit; and CoreFoundation/CoreImage under those. glib arrives
        # even though ffmpeg never links it directly — librsvg is a Rust `staticlib`
        # whose archive BUNDLES its native deps' objects. Ignored off darwin
        # (darwinFrameworkFlags is host-gated).
        requires.frameworks = [
          "VideoToolbox" "CoreMedia" "CoreVideo" "AVFoundation"
          "AudioToolbox" "CoreAudio" "OpenGL"
          "CoreText" "CoreGraphics" "CoreImage" "ImageIO" "Accelerate"
          "CoreServices" "CoreFoundation" "Foundation" "AppKit"
          "DiskArbitration"
        ];
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

      # darwin's libSystem doesn't ship libpthread.a so --enable-pthreads
      # breaks the configure probe; linux is fine.
      build = origPkgs:
        let
          # Overlay darwin-specific structural fixes into `pkgsStatic`
          # so every transitive consumer sees the patched libs (linux
          # passes through unchanged — each `nativeFixes.X` short-circuits
          # to `prev.X` on non-darwin).
          #
          # - `glib`: nixpkgs' linux→darwin meson cross-file lacks
          #   `objc`/`objcpp` binaries; glib's `add_languages('objc')`
          #   aborts. Fix injects a partial cross-file pointing at
          #   `$CC`/`$CXX` (clang handles `.m`/`.mm`). Unblocks the
          #   text-rendering chain (librsvg → pango → harfbuzz, libass).
          # - `graphite2`: cmake `nolib_test` uses
          #   `$<TARGET_SONAME_FILE>` which CMake refuses for STATIC
          #   libs. Upstream guards the call with `if (BUILD_SHARED_LIBS)`
          #   in the Linux branch but forgets to do it in the Darwin
          #   branch. Fix mirrors the guard. Pulled by harfbuzz.
          # - `fontconfig`: two upstream tests compare sysroot paths as
          #   strings; darwin's `/tmp → /private/tmp` symlink makes them
          #   disagree. Test bug, not a fontconfig defect — fix turns
          #   `doCheck` off on darwin. Pulled transitively by cairo.
          # - `pango`: same `add_languages('objc')` cross-file gap as
          #   glib, for the Core Text font backend; same fix.
          # - `cairo`: nixpkgs cross-file generation looks up
          #   `ipc_rmid_deferred_release` by `parsed.kernel.name` against
          #   { linux, freebsd, netbsd, windows } — darwin missing, throws.
          #   Bites cross-within-darwin (aarch64-darwin ↔ x86_64-darwin),
          #   the CI path; native x86_64-darwin from Intel Mac doesn't
          #   trip. Fix reconstructs mesonFlags with an equivalent
          #   cross-file that hard-codes 'false' (macOS shmctl IPC_RMID
          #   forbids subsequent attaches).
          # - `dav1d`: nixpkgs writes `cpu_family = 'arm64'` into the
          #   darwin-aarch64 meson cross-file; dav1d reads that as ARM-32
          #   and assembles `src/arm/32/*.S` with arm64 clang → "vector
          #   register expected". Patches the cpu_family branches to route
          #   'arm64' to the 64-bit asm dispatch. Bites the native
          #   darwin-aarch64 CI runner (the `--enable-libdav1d` dep).
          # - `libopus`: same `cpu_family = 'arm64'` cross-file mismatch;
          #   opus's meson.build only matches `['arm', 'aarch64']`, so
          #   the NEON branch is skipped and it errors at line 617
          #   ("no intrinsics support for arm64"). Must live in the
          #   overlay (not just ffmpeg's direct buildInputs) because
          #   libsndfile → rubberband pull libopus transitively and would
          #   otherwise get the unpatched build.
          # - `fftw`: nixpkgs drags `gfortran-wrapper` into fftw's
          #   nativeBuildInputs on EVERY platform although fftw never
          #   enables Fortran, forcing a full cross-GCC build (~30-60 min,
          #   not on cache.nixos.org; a hard failure on darwin). The nix-lib
          #   fix strips it (output-neutral). Apply as an overlay so the
          #   transitive consumers — rubberband (double), speex/speexdsp
          #   (single) — rebuild against the gfortran-free fftw instead of
          #   each dragging cross-gfortran. ffmpeg has no fftw feature of
          #   its own; it's purely transitive. The fix targets `pkgs.fftw`,
          #   so feed it `fftwFloat` via an attr-swap to reuse the same
          #   logic (incl. the darwin openmp side-step) for single precision.
          pkgs = origPkgs // {
            pkgsStatic = origPkgs.pkgsStatic.extend (final: prev:
              {
                fftw      = ulib.nativeFixes.fftw prev;
                fftwFloat = ulib.nativeFixes.fftw (prev // { fftw = prev.fftwFloat; });
                # libsndfile (pulled transitively) links the `libmpg123` attr —
                # a distinct, already-libOnly package, NOT `mpg123` — whose
                # mpg123/out123 CLI still gets built and dies on the engine LTO
                # `undefined symbol: fputs`. Route it through the same lib-only
                # fix (adds `--disable-components`). Overlay only `libmpg123`, not
                # `mpg123`: libopenmpt re-applies `nativeFixes.mpg123` via
                # `.override`, which would discard our overrideAttrs on an
                # already-overlaid `mpg123`.
                libmpg123 = ulib.nativeFixes.mpg123 prev;
              }
              # Two i686-only codec fixes (same as sox — the engine cross-compiles
              # every linux target with clang, including i686). Gated to isx86_32
              # so every other arch keeps its cache hit.
              // (if origPkgs.stdenv.hostPlatform.isx86_32 then {
                # lame's `#ifdef HAVE_XMMINTRIN_H` SSE paths (__m128) don't compile
                # on i686's -march=i686 baseline (no SSE); configure defines the
                # macro anyway because its `_mm_sfence()` probe runs with clang's
                # SSE2-capable default flags BEFORE lame appends -march=i686. Undef
                # it post-configure → SSE blocks fall back to their scalar code.
                lame = prev.lame.overrideAttrs (o: {
                  postConfigure = (o.postConfigure or "") + ''
                    sed -i '/#define HAVE_XMMINTRIN_H 1/d' config.h
                  '';
                });
                # libvorbis' 32-bit-x86 CFLAGS case hardcodes `-mno-ieee-fp`, a
                # GCC-only flag the engine clang rejects as fatal. It only relaxes
                # IEEE FP for -ffast-math (already on); drop it.
                libvorbis = prev.libvorbis.overrideAttrs (o: {
                  postPatch = (o.postPatch or "") + ''
                    substituteInPlace configure --replace-fail ' -mno-ieee-fp' ""
                  '';
                });
              } else { })
              // (if origPkgs.stdenv.hostPlatform.isDarwin then {
                glib       = ulib.nativeFixes.glib       prev;
                fontconfig = ulib.nativeFixes.fontconfig prev;
                pango      = ulib.nativeFixes.pango      prev;
                cairo      = ulib.nativeFixes.cairo      prev;
                dav1d      = ulib.nativeFixes.dav1d      prev;
                libopus    = ulib.nativeFixes.libopus    prev;
              } else { })
              # riscv64 libjpeg-turbo's broken RVV simdcoverage helper is dropped
              # SET-WIDE in nix-lib now (withLibjpegNoLto for the engine scope +
              # the librsvg pristine scope), since librsvg's transitive libjpeg
              # never passes through this per-flake overlay. Nothing to do here.
            );
          };
          isDarwin = pkgs.stdenv.isDarwin;
          isLinux = pkgs.stdenv.hostPlatform.isLinux;
          # nixpkgs `pkgsStatic.libcaca` puxa `imlib2 (x11Support=true)` +
          # libX11 + libXext porque o default da recipe é `x11Support ?
          # !stdenv.isDarwin`. Em pkgsStatic isso quebra (imlib2 com X11
          # cai em libX11 → fontconfig → expat chain inviável). ffmpeg só
          # usa o `caca_outdev` que renderiza no terminal via ncurses ou
          # slang — X11 não é caminho. `.override { x11Support = false; }`
          # desativa o flag de configure (`--disable-x11`) e cai pro
          # imlib2 sem X (que builda fino).
          #
          # Segundo trap: libcaca autotools recurse sempre em SUBDIRS=
          # `kernel caca src examples tools cxx`. O `examples/conio.c:76`
          # define uma `move()` local que colide com ncurses `move()` em
          # link estático (`multiple definition of move`). Não há flag
          # autoconf pra disable-examples — a saída é limitar build +
          # install ao subdir `caca/` (que tem o .a + caca.pc + headers,
          # tudo que ffmpeg precisa). Outputs vão pra ["out" "dev"] (sem
          # `bin` porque não buildamos `tools/caca-config`).
          libcacaTerm = (pkgs.pkgsStatic.libcaca.override { x11Support = false; }).overrideAttrs (oa: {
            outputs = [ "out" "dev" ];
            buildPhase = ''
              runHook preBuild
              make -C caca
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              make -C caca install
              runHook postInstall
            '';
            postInstall = "";
            # libcaca's caca.pc declares `Libs.private: -lz` mas omite o
            # ncurses driver (`-lncursesw`), apesar do .a usar `curs_set`,
            # `initscr`, etc. Em distros normais (dynamic-link) o consumer
            # carrega ncurses.so transitivamente; em pkgsStatic + ffmpeg
            # `--pkg-config-flags=--static` o link falha com `undefined
            # reference to curs_set`. Appendar `Requires.private: ncursesw`
            # → pkg-config resolve ncursesw.pc e injeta `-lncursesw` no
            # tail do link line.
            postFixup = (oa.postFixup or "") + ''
              echo 'Requires.private: ncursesw' \
                >> $dev/lib/pkgconfig/caca.pc
            '';
          });
          sharedExtras = mkExtras pkgs.pkgsStatic;
          # Linux-only extras: kernel/Linux-specific or
          # cross-build-blocked-on-darwin features.
          #   - libdrm/kmsgrab: KMS is a Linux kernel ABI
          #   - libxcb/x11grab: X11 socket — macOS isn't headless X
          #   - libcdio/libcdio-paranoia: Linux CDDA ioctls
          #   - libcaca: terminal output device, niche; pulls ncurses
          #   - librsvg: heavy Rust+GTK chain, validate cross-target later
          #   - libass + freetype + harfbuzz + fribidi + fontconfig:
          #     harfbuzz pulls glib unconditionally; glib's meson.build
          #     requires `objc` compiler in the cross [binaries] section
          #     when host_system == 'darwin', and our linux→darwin
          #     cross-file doesn't supply objc. Defer until a proper
          #     objc cross-wrapper exists (or harfbuzz gains a
          #     `withGlib=false` knob).
          linuxOnlyExtras =
            if isLinux then {
              flags = [
                "--enable-libcaca"
                "--enable-libcdio"
                "--enable-libdrm"
                "--enable-libxcb"
                "--enable-libxcb-shm"
                "--enable-libxcb-xfixes"
                "--enable-libxcb-shape"
              ];
              inputs = with pkgs.pkgsStatic; [
                libcdio      libcdio.dev
                libcdio-paranoia
                libdrm       libdrm.dev
                xorg.libxcb  xorg.libxcb.dev
              ] ++ [ libcacaTerm libcacaTerm.dev ];
            } else { flags = [ ]; inputs = [ ]; };
          extras = {
            flags = sharedExtras.flags ++ linuxOnlyExtras.flags;
            inputs = sharedExtras.inputs ++ linuxOnlyExtras.inputs;
          };
        in
        mkFfmpeg pkgs.pkgsStatic {
          extraConfigureFlags =
            (if isDarwin then [ ] else [ "--enable-pthreads" ])
            ++ extras.flags;
          extraInputs = extras.inputs;
        };

      # mingw: force pthreads (not w32threads) to match downstream codec
      # libs (x264, dav1d) that were built against pthreads. Same
      # `sharedExtras` feature set as linux/darwin — the per-package
      # `nativeFixes.X` registry handles mingw quirks transparently.
      #
      # mingw is off-engine, so the bitcode self-fold that gives linux/darwin a
      # single `ffmpeg` with `ffprobe` as an argv[0] alias doesn't run here;
      # ./multicall.nix does the equivalent fold by recompiling each program's
      # fftools objects behind a per-program rename header.
      windowsBuild = pkgs:
        let
          cross = ulib.mingwStaticCross pkgs;
          extras = mkExtras cross;
        in
        import ./multicall.nix { lib = cross.lib // ulib; } {
          pkgs = cross;
          ffmpeg = mkFfmpeg cross {
            extraConfigureFlags =
              [ "--disable-w32threads" "--enable-pthreads" ]
              ++ extras.flags;
            extraInputs = [ cross.windows.pthreads ] ++ extras.inputs;
          };
        };
    };
}
