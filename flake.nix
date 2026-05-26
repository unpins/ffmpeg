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
            # ffmpeg's cc_default="gcc" — appended after cross-prefix
            # this gives `arm64-apple-darwin-gcc`, which doesn't exist
            # on darwin (clang backend). Force the wrapper symlink that
            # exists across both clang and gcc nixpkgs cc-wrappers.
            "--cc=${stdenv.hostPlatform.config}-cc"
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
            "--disable-doc" "--disable-htmlpages" "--disable-manpages"
            "--disable-podpages" "--disable-txtpages"
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
          ++ (if isDarwin then [ ]
              else [ "--extra-ldflags=-static" "--enable-static" "--disable-shared" ])
          ++ extraConfigureFlags;
        in
        stdenv.mkDerivation {
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
          buildInputs = (with pkgs; [
            zlib bzip2 xz libiconv x264 libvorbis libogg lame zimg
          ]) ++ [
            (ulib.nativeFixes.libopus pkgs)
            (ulib.nativeFixes.dav1d pkgs)
          ] ++ extraInputs;

          strictDeps = true;
          enableParallelBuilding = true;
          stripAllList = [ "bin" ];

          configurePhase = ''
            runHook preConfigure
            # ffmpeg's `require_cpp_condition` for x264 trips on the
            # default x264.h header decoration; drop the check.
            sed -i '/X264_API_IMPORTS/d' configure
            ./configure ${builtins.concatStringsSep " " flags}
            runHook postConfigure
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp ffmpeg${exe} ffprobe${exe} $out/bin/
            runHook postInstall
          '';

          passthru = { pname = "ffmpeg"; inherit (pkgs.ffmpeg-headless) version; };
        };
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "ffmpeg";

      # darwin's libSystem doesn't ship libpthread.a so --enable-pthreads
      # breaks the configure probe; linux is fine.
      build = pkgs:
        let
          isDarwin = pkgs.stdenv.isDarwin;
          isLinux = pkgs.stdenv.hostPlatform.isLinux;
          # nixpkgs's svt-av1 defaults to `-DSVT_AV1_LTO=ON` which makes the
          # static archive ship only LTO IR (`__gnu_lto_slim` is the only
          # symbol the regular .symtab carries). ffmpeg's pkg-config link
          # probe calls ld.bfd without `-flto`/the LTO plugin, so the probe
          # fails with `undefined reference to svt_av1_enc_init_handle`.
          # Append `-DSVT_AV1_LTO=OFF` (cmake takes last-wins for `-D…`).
          svtAv1NoLto = (pkgs.pkgsStatic.svt-av1.overrideAttrs (oa: {
            cmakeFlags = (oa.cmakeFlags or [ ]) ++ [ "-DSVT_AV1_LTO=OFF" ];
          }));
          # nixpkgs x265 in pkgsStatic needs two surgical patches:
          #
          #  1. Multi-bit-depth archives stay separate. With the default
          #     `multibitdepthSupport = true`, the x265 build produces
          #     three archives — main (8-bit), `libx265-10.a`,
          #     `libx265-12.a` — and the main archive references
          #     `x265_10bit::` / `x265_12bit::` symbols from the siblings.
          #     The dynamic-lib build merges them into a single `.so`;
          #     pkgsStatic suppresses the `.so` and leaves the static
          #     archives unmerged, so any consumer linking `-lx265` sees
          #     undefined references. We merge the three with `ar -M`
          #     into a self-contained `libx265.a` (postBuild). Cutting
          #     `multibitdepthSupport` instead would drop Main10 (HDR10)
          #     and Main12 — too much loss for a static-lib rebundle.
          #
          #  2. `rm -f $out/lib/*.a` in upstream postInstall — correct for
          #     the dynamic default, fatal for pkgsStatic. Replace with
          #     an empty postInstall.
          # libbluray.a exposes plenty of internal symbols as globals
          # (decode_*, udfread_*, dec_*) instead of `static`. `dec_init`
          # in particular collides with ffmpeg's own `dec_init` in
          # fftools/ffmpeg_dec.c at static link time. Localize it via
          # `objcopy --localize-symbol`: keeps the public bd_* API
          # globally visible but makes the colliding name file-local.
          # Targeted (one symbol) rather than wholesale whitelist —
          # extend the list if other collisions surface.
          # nixpkgs `pkgsStatic.rtmpdump`: two issues stacked.
          #
          #  1. Makefile's `SHARED=yes` default builds librtmp.so.1
          #     unconditionally; pkgsStatic toolchain can't link `.so`
          #     (crtbeginT.o R_X86_64_32 against __TMC_END__). Override
          #     `SHARED=no` so the top-level `all` target reduces to
          #     just `librtmp.a`.
          #
          #  2. Default `CRYPTO=OPENSSL` drags OpenSSL back into the
          #     closure (we worked to remove it via mbedtls swap on srt
          #     and libssh). Override to `CRYPTO=` (empty) which maps
          #     to `DEF_=-DNO_CRYPTO` in the Makefile — drops RTMPS via
          #     librtmp. ffmpeg's own protocol handlers cover `rtmps://`
          #     through `--enable-mbedtls`, so the user-visible feature
          #     is preserved; we just don't route RTMPS through
          #     librtmp anymore. POLARSSL is the only no-OpenSSL knob
          #     librtmp ships, but its API is mbedtls 1.x/2.x — won't
          #     compile against modern 3.x without API shims.
          rtmpdumpStatic = pkgs.pkgsStatic.rtmpdump.overrideAttrs (oa: {
            makeFlags = (oa.makeFlags or [ ]) ++ [ "SHARED=no" "CRYPTO=" ];
            propagatedBuildInputs = [ pkgs.pkgsStatic.zlib ];
          });
          libbluraySafe = pkgs.pkgsStatic.libbluray.overrideAttrs (oa: {
            # libbluray.a leaks internal helpers as globals — `dec_init`
            # in particular collides with ffmpeg's own `dec_init` in
            # fftools/ffmpeg_dec.c at static link time. `--localize-
            # symbol` makes it file-local to dec.o, but then sibling
            # object disc.o (calling dec_init) loses access. Use
            # `--redefine-sym` instead: rewrites both the definition
            # *and* internal references inside every .o of the archive,
            # so libbluray stays self-consistent while the renamed
            # symbol no longer matches ffmpeg's `dec_init`.
            postInstall = (oa.postInstall or "") + ''
              echo "renaming dec_init -> bluray_internal_dec_init in libbluray.a"
              $OBJCOPY --redefine-sym=dec_init=bluray_internal_dec_init \
                $out/lib/libbluray.a
            '';
          });
          # nixpkgs `pkgsStatic.libssh` defaults to OpenSSL via
          # `find_package(OpenSSL)`. Like srt, swap to mbedtls so we keep
          # one crypto backend in the closure. libssh's CMake supports
          # `-DWITH_MBEDTLS=ON` (ships its own `FindMbedTLS.cmake`).
          # buildInputs reordered (no openssl); propagatedBuildInputs
          # MUST be replaced (pkgsStatic auto-promotes buildInputs into
          # it — see [[pkgsstatic-propagated-buildinputs]] /
          # [[srt-pkgsstatic-mbedtls-swap]]).
          libsshMbed = pkgs.pkgsStatic.libssh.overrideAttrs (oa: {
            buildInputs = [
              pkgs.pkgsStatic.zlib
              pkgs.pkgsStatic.mbedtls
              pkgs.pkgsStatic.libsodium
            ];
            propagatedBuildInputs = [
              pkgs.pkgsStatic.zlib
              pkgs.pkgsStatic.mbedtls
              pkgs.pkgsStatic.libsodium
            ];
            cmakeFlags = (oa.cmakeFlags or [ ]) ++ [ "-DWITH_MBEDTLS=ON" ];
            # libssh's libssh.pc.cmake leaves Requires.private empty for
            # the crypto backend (CMakeLists only appends gssapi to
            # `LIBSSH_PC_REQUIRES_PRIVATE`). Without it, consumers
            # using `pkg-config --static` get no transitive crypto link
            # flags — ffmpeg's probe fails with `mbedtls_*` undefined.
            # Inject Requires.private so pkg-config resolves mbedtls.pc
            # / libsodium.pc / zlib.pc and emits the missing -L/-l.
            # postFixup (not postInstall) — multipleOutputsPhase moves
            # the .pc to $dev after install runs, so sed needs to wait.
            postFixup = (oa.postFixup or "") + ''
              # Append (CMake drops the Requires.private line entirely
              # when LIBSSH_PC_REQUIRES_PRIVATE is empty), don't try to
              # replace.
              echo 'Requires.private: mbedtls libsodium zlib' \
                >> $dev/lib/pkgconfig/libssh.pc
            '';
          });
          # nixpkgs xvidcore: Makefile always builds both libxvidcore.a
          # AND libxvidcore.so.4.3. pkgsStatic toolchain fails the .so
          # link with `R_X86_64_32 against hidden symbol __TMC_END__` —
          # static-PIE startup (crtbeginT.o) can't go into a shared
          # object. Build only the static target. Also drop the
          # upstream `rm $out/lib/*.a` postInstall trap (same shape as
          # x265 — see [[x265-pkgsstatic-recipe]]).
          xvidStatic = pkgs.pkgsStatic.xvidcore.overrideAttrs (oa: {
            # Build only the static target; xvid's Makefile's default
            # 'all' goal also makes the .so which the pkgsStatic
            # toolchain can't link.
            makeFlags = (oa.makeFlags or [ ]) ++ [ "libxvidcore.a" ];
            # Skip 'make install' (it wants the .so we didn't build).
            # Install the .a + header by hand instead. The .a lands in
            # `=build/` (a literal directory name xvid uses) inside the
            # configure cwd build/generic/.
            installPhase = ''
              runHook preInstall
              install -Dm644 =build/libxvidcore.a $out/lib/libxvidcore.a
              install -Dm644 ../../src/xvid.h $out/include/xvid.h
              runHook postInstall
            '';
            postInstall = "";
          });
          # nixpkgs `pkgsStatic.srt` defaults to openssl crypto. We already
          # carry mbedtls in this flake for `--enable-mbedtls`, so swap srt
          # to the same backend: drops openssl from the closure entirely
          # (no double-crypto). srt's CMake supports
          # `-DUSE_ENCLIB=mbedtls` and ships `scripts/FindMbedTLS.cmake`,
          # which discovers our static mbedtls via CMAKE_PREFIX_PATH.
          srtMbed = pkgs.pkgsStatic.srt.overrideAttrs (oa: {
            buildInputs = [ pkgs.pkgsStatic.mbedtls ]
              ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isMinGW [
                pkgs.pkgsStatic.windows.pthreads
              ];
            # srt's CMake bakes absolute /nix/store/.../libmbedtls.a paths
            # into `Libs.private` of `srt.pc`. ffmpeg's `--pkg-config-
            # flags=--static` probe puts those absolute paths *before*
            # the test object on the link command, and `-Wl,--as-needed`
            # drops them (no unresolved refs yet); then `-lsrt` (after
            # test.o) introduces mbedtls refs that nothing remains to
            # resolve. Rewrite to `-l` form and propagate mbedtls so the
            # cc-wrapper appends `-L${mbedtls}/lib -lmbedtls…` at the
            # tail of the link line, after `-lsrt`.
            # pkgsStatic auto-promotes buildInputs → propagatedBuildInputs
            # at scope creation, so the original openssl from upstream's
            # buildInputs is already sitting in `oa.propagatedBuildInputs`.
            # We must *replace*, not extend, or openssl stays in the closure.
            propagatedBuildInputs = [ pkgs.pkgsStatic.mbedtls ];
            cmakeFlags = (oa.cmakeFlags or [ ]) ++ [
              "-DUSE_ENCLIB=mbedtls"
              "-DENABLE_APPS=OFF"
            ];
            postInstall = (oa.postInstall or "") + ''
              sed -i -E 's|[^ ]*/lib(mbed[a-z0-9]+)\.a|-l\1|g' \
                $out/lib/pkgconfig/srt.pc
            '';
          });
          # soxr defaults `-DWITH_OPENMP=ON` (parallel resampling), pulling
          # in `libgomp` undefined refs (`GOMP_parallel`). Upstream's
          # `soxr.pc.in` declares no `Libs.private`, and ffmpeg's libsoxr
          # probe is `require` (not `require_pkg_config`) so .pc is unread
          # anyway — the consumer would need `--extra-libs=-lgomp` to link.
          # Since ffmpeg already parallelises audio resampling at the
          # filtergraph level (libavfilter thread pool), soxr-OpenMP just
          # creates thread-on-thread oversubscription — feature is
          # redundant in this consumer, so we turn it off rather than
          # threading libgomp through the link line for no real benefit.
          soxrNoOmp = pkgs.pkgsStatic.soxr.overrideAttrs (oa: {
            cmakeFlags = (oa.cmakeFlags or [ ]) ++ [ "-DWITH_OPENMP=OFF" ];
          });
          # nixpkgs librist enables tests + built_tools by default. The
          # cmocka-based test files (srp_examples.c, srp_unit.c) redefine
          # `free` as `_test_free(...)` via a header pragma; cmocka 1.x +
          # musl's stdlib (`__attribute_malloc__` decoration on `free`)
          # collide and the test sources fail to compile. We don't need
          # tests or CLI tools — disable both. Mainline librist.a builds
          # clean once those targets are gone.
          libristNoTest = pkgs.pkgsStatic.librist.overrideAttrs (oa: {
            mesonFlags = (oa.mesonFlags or [ ]) ++ [
              "-Dtest=false"
              "-Dbuilt_tools=false"
            ];
          });
          # nixpkgs qrencode pulls SDL2 in `nativeCheckInputs` to run the
          # tests during the build. SDL2 → libglvnd which is `badPlatform`
          # on pkgsStatic (no GL on musl). The library itself doesn't
          # need SDL2 — only the test binary does. Disable the check
          # phase; mainline libqrencode.a + headers install fine.
          qrencodeNoCheck = pkgs.pkgsStatic.qrencode.overrideAttrs (oa: {
            doCheck = false;
          });
          # nixpkgs `pkgsStatic.librsvg`: meson runs
          # `rustc --target=x86_64-unknown-linux-musl --print=native-static-libs`
          # which prints `-lunwind -lc`, then calls
          # `cc.find_library('unwind', static: true)` for each — see
          # librsvg meson.build:375. nixpkgs doesn't ship libunwind in
          # the librsvg buildInputs because the dynamic-lib build resolves
          # `_Unwind_*` via libgcc_s at runtime. In pkgsStatic the probe
          # is hard-required. Alpine builds librsvg as `.so` only and
          # doesn't pass `-Ddefault_library=static`, so the probe never
          # fires — that's why their APKBUILD looks clean.
          #
          # Fix: feed the GCC libunwind (1.8.x, ~250 KB) as a buildInput.
          # llvmPackages.libunwind also works but is 4× the size; both
          # export the same `_Unwind_*` ABI so the static link succeeds
          # either way.
          librsvgStatic = pkgs.pkgsStatic.librsvg.overrideAttrs (oa: {
            buildInputs = (oa.buildInputs or [ ]) ++ [ pkgs.pkgsStatic.libunwind ];
          });
          # nixpkgs `pkgsStatic.rubberband` pulls vamp-plugin-sdk + lv2
          # + ladspa-header + jdk_headless as build inputs because the
          # upstream Makefile *emits* a Vamp plugin / LADSPA plugin / LV2
          # plugin / Java JNI binding as side-targets. The core
          # `librubberband.a` doesn't consume any of them at link time —
          # they're separate `.so` outputs the build produces from the
          # same source tree. In pkgsStatic, the Vamp SDK's Makefile
          # unconditionally links `libvamp-sdk.so` (no SHARED-toggle knob),
          # which fails crtbeginT.o R_X86_64_32 — the now-familiar static-
          # PIE-in-shared-object trap. Disabling all four side-plugins
          # at meson configure (`-Dvamp=disabled` etc) drops every dep
          # we don't need and reduces the chain to fftw + libsamplerate.
          # propagatedBuildInputs must also be replaced (not extended) —
          # pkgsStatic auto-promotes upstream buildInputs into it, see
          # [[pkgsstatic-propagated-buildinputs]] /
          # [[srt-pkgsstatic-mbedtls-swap]].
          # nixpkgs `pkgsStatic.chromaprint` carrega `ffmpeg-headless`
          # em buildInputs por causa do binário `fpcalc` (CLI tool que
          # decodifica áudio via libav* antes de fingerprintar). A lib
          # `libchromaprint.a` em si não toca em libavcodec — o decode
          # é gerado pelo consumer. Em pkgsStatic isso vira circular
          # (queremos ffmpeg → chromaprint, mas chromaprint → ffmpeg)
          # E pior: o ffmpeg-headless de upstream puxa libpulseaudio em
          # propagatedBuildInputs, que é `badPlatform` em musl.
          # Disable `withTools` + `withExamples` + zera buildInputs +
          # propagatedBuildInputs. zlib não é necessário pra core lib.
          chromaprintLean = (pkgs.pkgsStatic.chromaprint.override {
            withTools = false;
            withExamples = false;
          }).overrideAttrs (oa: {
            buildInputs = [ ];
            propagatedBuildInputs = [ ];
            # libchromaprint.a é C++ (sources em src/*.cpp). Upstream's
            # libchromaprint.pc omite Libs.private — em distros normais
            # o consumer dynamic-lib pega libstdc++.so do sistema. Em
            # pkgsStatic + ffmpeg `--pkg-config-flags=--static`, sem
            # Libs.private o probe `chromaprint_get_version` link falha
            # com `undefined reference to __cxa_*` e `cosf`. Appendar
            # explicitamente.
            postInstall = (oa.postInstall or "") + ''
              echo 'Libs.private: -lstdc++ -lm' \
                >> $out/lib/pkgconfig/libchromaprint.pc
            '';
          });
          # nixpkgs `pkgsStatic.game-music-emu` postFixup faz
          # `remove-references-to -t cc $(readlink -f $out/lib/libgme.so)`
          # — em pkgsStatic não há .so; readlink retorna vazio e o
          # `remove-references-to` fallback pra sed sem input gera
          # "sed: no input files" → exit 1. Como não temos .so, drop
          # postFixup inteiro (a .a já não referencia o gcc do build).
          gmeStatic = pkgs.pkgsStatic.game-music-emu.overrideAttrs (oa: {
            postFixup = "";
          });
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
          rubberbandLean = pkgs.pkgsStatic.rubberband.overrideAttrs (oa: {
            nativeBuildInputs = builtins.filter
              (d: !(d.pname or null == "openjdk-headless"))
              (oa.nativeBuildInputs or [ ]);
            buildInputs = with pkgs.pkgsStatic; [ fftw libsamplerate ];
            propagatedBuildInputs = with pkgs.pkgsStatic; [ fftw libsamplerate ];
            mesonFlags = (oa.mesonFlags or [ ]) ++ [
              "-Dvamp=disabled"
              "-Dladspa=disabled"
              "-Dlv2=disabled"
              "-Djni=disabled"
              "-Dcmdline=disabled"
              "-Dtests=disabled"
              "-Dfft=fftw"
              "-Dresampler=libsamplerate"
            ];
          });
          x265Static = pkgs.pkgsStatic.x265.overrideAttrs (oa: {
            postBuild = (oa.postBuild or "") + ''
              echo "merging libx265.a + libx265-10.a + libx265-12.a → unified libx265.a"
              $AR -M <<'EOF'
              CREATE libx265-merged.a
              ADDLIB libx265.a
              ADDLIB libx265-10.a
              ADDLIB libx265-12.a
              SAVE
              END
              EOF
              mv libx265-merged.a libx265.a
            '';
            postInstall = "";
          });
          linuxExtras =
            if isLinux then {
              flags = [
                "--enable-mbedtls"
                "--enable-libsvtav1"
                "--enable-libx265"
                "--enable-libass"
                "--enable-libfreetype"
                "--enable-libharfbuzz"
                "--enable-libfribidi"
                "--enable-libwebp"
                "--enable-libvpx"
                "--enable-libsoxr"
                "--enable-libtheora"
                "--enable-libsrt"
                "--enable-libaom"
                "--enable-libopenjpeg"
                "--enable-libxml2"
                "--enable-libxvid"
                "--enable-libmodplug"
                "--enable-libtwolame"
                "--enable-libspeex"
                "--enable-libssh"
                "--enable-libbluray"
                "--enable-librtmp"
                "--enable-librist"
                "--enable-libqrencode"
                "--enable-libfontconfig"
                "--enable-libopencore-amrnb"
                "--enable-libopencore-amrwb"
                "--enable-librsvg"
                "--enable-libvidstab"
                "--enable-librubberband"
                "--enable-chromaprint"
                "--enable-libzvbi"
                "--enable-libgme"
                "--enable-libcaca"
                "--enable-libcdio"
              ];
              # Multi-output deps need both outputs in buildInputs:
              # `out` (the .a) plus `.dev` (the .pc + headers). Without
              # `.dev`, ffmpeg's pkg-config probe fails silently. libwebp
              # is single-output so the bare entry is enough.
              inputs = with pkgs.pkgsStatic; [
                mbedtls
                libass    libass.dev
                freetype  freetype.dev
                harfbuzz  harfbuzz.dev
                fribidi   fribidi.dev
                libwebp
                libvpx       libvpx.dev
                libtheora    libtheora.dev
                libaom       libaom.dev
                openjpeg     openjpeg.dev
                libxml2      libxml2.dev
                libmodplug   libmodplug.dev
                twolame
                speex        speex.dev
                fontconfig   fontconfig.dev
                opencore-amr
                vid-stab
                zvbi         zvbi.dev
                libcdio      libcdio.dev
                libcdio-paranoia
              ] ++ [ svtAv1NoLto x265Static x265Static.dev soxrNoOmp soxrNoOmp.dev srtMbed xvidStatic libsshMbed libsshMbed.dev libbluraySafe rtmpdumpStatic rtmpdumpStatic.dev libristNoTest qrencodeNoCheck qrencodeNoCheck.dev librsvgStatic librsvgStatic.dev pkgs.pkgsStatic.libunwind rubberbandLean chromaprintLean gmeStatic libcacaTerm libcacaTerm.dev ];
            } else { flags = [ ]; inputs = [ ]; };
        in
        mkFfmpeg pkgs.pkgsStatic {
          extraConfigureFlags =
            (if isDarwin then [ ] else [ "--enable-pthreads" ])
            ++ linuxExtras.flags;
          extraInputs = linuxExtras.inputs;
        };

      # mingw: force pthreads (not w32threads) to match downstream codec
      # libs (x264, dav1d) that were built against pthreads.
      windowsBuild = pkgs:
        let cross = ulib.mingwStaticCross pkgs; in
        mkFfmpeg cross {
          extraConfigureFlags = [ "--disable-w32threads" "--enable-pthreads" ];
          extraInputs = [ cross.windows.pthreads ];
        };
    };
}
