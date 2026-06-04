{
  description = "Standalone build of ffmpeg (headless)";

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
              else [ "--extra-ldflags=-static" "--enable-static" "--disable-shared" ])
          ++ extraConfigureFlags;
        in
        stdenv.mkDerivation ({
          pname = "ffmpeg";
          inherit (pkgs.ffmpeg-headless) version src;

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

          configurePhase = ''
            runHook preConfigure
            ${pkgs.lib.optionalString isDarwin ''
              # See the darwin `--extra-libs` note above. Expose the static
              # libc++ as libc++.a + libstdc++.a (+ libc++abi.a) on a search
              # path that precedes the dylib dirs, so every -lc++/-lstdc++
              # from ffmpeg's configure and the dep `.pc` files links static.
              mkdir -p "$TMPDIR/cxx-static"
              ln -sf ${pkgs.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libc++.a"
              ln -sf ${pkgs.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libstdc++.a"
              ln -sf ${pkgs.libcxx}/lib/libc++abi.a "$TMPDIR/cxx-static/libc++abi.a"
              export NIX_LDFLAGS="-L$TMPDIR/cxx-static $NIX_LDFLAGS"
            ''}
            # ffmpeg's `require_cpp_condition` for x264 trips on the
            # default x264.h header decoration; drop the check.
            sed -i '/X264_API_IMPORTS/d' configure
            ./configure ${builtins.concatStringsSep " " flags}
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
        } // pkgs.lib.optionalAttrs (stdenv.hostPlatform.isRiscV or false) {
          # riscv64: musl's <bits/syscall.h> predates the riscv_hwprobe
          # syscall (Linux 6.4), but the cross kernel headers ship
          # <asm/hwprobe.h>. ffmpeg's libavutil/riscv/cpu.c then includes
          # the struct and calls syscall(__NR_riscv_hwprobe, ...) with the
          # number undefined → "'__NR_riscv_hwprobe' undeclared". Define the
          # canonical riscv value (258) when the libc headers lack it, after
          # the real include so a newer musl still wins. Keeps
          # --enable-runtime-cpudetect's V-extension probe working.
          postPatch = ''
            sed -i 's|#include <sys/syscall.h>|#include <sys/syscall.h>\n#ifndef __NR_riscv_hwprobe\n#define __NR_riscv_hwprobe 258\n#endif|' libavutil/riscv/cpu.c
          '';
        });
      # `mkExtras` returns the cross-platform set of feature flags and
      # build inputs that ride on `sharedExtras`. Parameterised on a
      # `pkgsStatic`-like scope so the same registry of fixes applies
      # uniformly to linux, darwin, and mingw — each `nativeFixes.X` is
      # platform-aware (no-op on platforms where the upstream is already
      # fine).
      mkExtras = pkgsStaticScope:
        let
          # Direct (no-feature-disable) fixes pulled in from nix-lib's
          # native-overlay. See `nix-lib/native-overlay/<pkg>.nix` for
          # the per-package rationale.
          svtAv1NoLto    = ulib.nativeFixes.svt-av1        pkgsStaticScope;
          x265Static     = ulib.nativeFixes.x265           pkgsStaticScope;
          xvidStatic     = ulib.nativeFixes.xvidcore       pkgsStaticScope;
          gmeStatic      = ulib.nativeFixes.game-music-emu pkgsStaticScope;
          librsvgStatic  = ulib.nativeFixes.librsvg        pkgsStaticScope;
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
            # libunwind only needed for musl Rust targets (librsvg's
            # rustc --print=native-static-libs returns -lunwind).
            # mingw uses SEH; libunwind doesn't build there (ucontext.h
            # POSIX-only) and isn't needed.
            ++ (if pkgsStaticScope.stdenv.hostPlatform.isMinGW or false
                then [ ]
                else [ pkgsStaticScope.libunwind ]);
        };
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "ffmpeg";

      # No winManRoot: the mingw windows .exe builds + installs the same 13
      # curated man pages as native (the installPhase `make`s doc/*.1 via
      # build-host perl on every target), so it harvests its OWN man — exactly
      # the pages native/darwin embed, no nixpkgs graft.

      # Execute the built binary in CI (esp. windows-x86_64, which only
      # runs here). `-version` prints the banner + full configure line.
      smoke = [ "-version" ];
      smokePattern = "ffmpeg version";

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
              }
              // (if origPkgs.stdenv.hostPlatform.isDarwin then {
                glib       = ulib.nativeFixes.glib       prev;
                graphite2  = ulib.nativeFixes.graphite2  prev;
                fontconfig = ulib.nativeFixes.fontconfig prev;
                pango      = ulib.nativeFixes.pango      prev;
                cairo      = ulib.nativeFixes.cairo      prev;
                dav1d      = ulib.nativeFixes.dav1d      prev;
                libopus    = ulib.nativeFixes.libopus    prev;
              } else { })
              # riscv64: libjpeg-turbo's RVV SIMD coverage helper fails to
              # compile (see nix-lib/native-overlay/libjpeg-turbo.nix). Pulled
              # transitively via librsvg → gdk-pixbuf/libtiff/libwebp plus
              # openjpeg/libcaca. Gate to riscv so the other arches keep the
              # unmodified (cache-hit) libjpeg.
              // (if origPkgs.stdenv.hostPlatform.isRiscV then {
                libjpeg = ulib.nativeFixes."libjpeg-turbo" prev;
              } else { })
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
      windowsBuild = pkgs:
        let
          cross = ulib.mingwStaticCross pkgs;
          extras = mkExtras cross;
        in
        mkFfmpeg cross {
          extraConfigureFlags =
            [ "--disable-w32threads" "--enable-pthreads" ]
            ++ extras.flags;
          extraInputs = [ cross.windows.pthreads ] ++ extras.inputs;
        };
    };
}
